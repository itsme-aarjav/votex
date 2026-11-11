import os
import sys
import json
import time
import uuid
import socket
import signal
import logging
import datetime
from typing import Dict, Any, Optional

import redis
import psycopg2
from psycopg2 import pool, extras

# OpenTelemetry distributed tracing (safe fallback if disabled)
OTEL_ENABLED = os.getenv('OTEL_ENABLED', 'true').lower() in ('true', '1')
tracer = None

if OTEL_ENABLED:
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
        from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator

        provider = TracerProvider(id_generator=AwsXRayIdGenerator())
        otlp_endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT')
        if otlp_endpoint:
            try:
                from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
                exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
                provider.add_span_processor(BatchSpanProcessor(exporter))
            except Exception as exp_err:
                logging.warning("OTLP worker exporter initialization deferred: %s", exp_err)
        trace.set_tracer_provider(provider)
        tracer = trace.get_tracer("votex-worker", "2.1.0")
    except Exception as otel_err:
        logging.warning("OpenTelemetry worker initialization skipped: %s", otel_err)
        tracer = None

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","service":"votex-worker","message":"%(message)s"}'
)
logger = logging.getLogger("worker")

STREAM_KEY = os.getenv('REDIS_STREAM_KEY', 'votes_stream')
GROUP_NAME = os.getenv('REDIS_GROUP_NAME', 'votex_workers')
LEGACY_QUEUE_KEY = os.getenv('REDIS_LEGACY_QUEUE', 'votes')
AUTOCLAIM_INTERVAL_SEC = 5.0
AUTOCLAIM_IDLE_MS = 30000  # 30 seconds

running = True


def handle_shutdown(signum, frame):
    global running
    logger.info("Received termination signal %s. Initiating graceful shutdown...", signum)
    running = False


signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def get_db_connection():
    pg_host = os.getenv('POSTGRES_HOST', 'db')
    pg_port = int(os.getenv('POSTGRES_PORT', 5432))
    pg_user = os.getenv('POSTGRES_USER', 'postgres')
    pg_pass = os.getenv('POSTGRES_PASSWORD', '')
    pg_db = os.getenv('POSTGRES_DB', 'postgres')
    db_url = os.getenv('DATABASE_URL')

    while running:
        try:
            if db_url:
                conn = psycopg2.connect(dsn=db_url)
            else:
                conn = psycopg2.connect(
                    host=pg_host,
                    port=pg_port,
                    user=pg_user,
                    password=pg_pass,
                    dbname=pg_db,
                    connect_timeout=5
                )
            conn.autocommit = False
            logger.info("Connected to PostgreSQL database successfully.")
            return conn
        except Exception as ex:
            logger.warning("Waiting for PostgreSQL database (%s:%s): %s", pg_host, pg_port, ex)
            time.sleep(2)
    return None


def get_redis_client():
    r_host = os.getenv('REDIS_HOST', 'redis')
    r_port = int(os.getenv('REDIS_PORT', 6379))

    while running:
        try:
            r = redis.Redis(
                host=r_host,
                port=r_port,
                db=0,
                decode_responses=True,
                socket_timeout=5,
                socket_connect_timeout=5
            )
            r.ping()
            logger.info("Connected to Redis successfully at %s:%s.", r_host, r_port)
            return r
        except Exception as ex:
            logger.warning("Waiting for Redis (%s:%s): %s", r_host, r_port, ex)
            time.sleep(2)
    return None


def init_database_schema(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS polls (
                id VARCHAR(64) PRIMARY KEY,
                title VARCHAR(255) NOT NULL,
                greeting VARCHAR(255) DEFAULT 'Hi!',
                creator VARCHAR(64) NOT NULL,
                image VARCHAR(512) DEFAULT '',
                option_a VARCHAR(128) NOT NULL,
                option_b VARCHAR(128) NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS votes (
                id VARCHAR(255) NOT NULL,
                poll_id VARCHAR(64) NOT NULL DEFAULT 'cats-dogs',
                vote VARCHAR(32) NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                CONSTRAINT pk_votes PRIMARY KEY (id, poll_id)
            );

            DO $$
            BEGIN
                IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'votes') THEN
                    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'votes' AND column_name = 'poll_id') THEN
                        ALTER TABLE votes ADD COLUMN poll_id VARCHAR(64) DEFAULT 'cats-dogs';
                    END IF;
                    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'votes' AND column_name = 'created_at') THEN
                        ALTER TABLE votes ADD COLUMN created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
                    END IF;
                    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'votes' AND column_name = 'updated_at') THEN
                        ALTER TABLE votes ADD COLUMN updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
                    END IF;
                    IF NOT EXISTS (
                        SELECT 1 FROM information_schema.table_constraints tc
                        JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
                        WHERE tc.table_name = 'votes' AND tc.constraint_type = 'PRIMARY KEY' AND kcu.column_name = 'poll_id'
                    ) THEN
                        ALTER TABLE votes DROP CONSTRAINT IF EXISTS votes_pkey CASCADE;
                        ALTER TABLE votes DROP CONSTRAINT IF EXISTS pk_votes CASCADE;
                        ALTER TABLE votes DROP CONSTRAINT IF EXISTS votes_id_key CASCADE;
                        ALTER TABLE votes ADD CONSTRAINT pk_votes PRIMARY KEY (id, poll_id);
                    END IF;
                END IF;
            END $$;

            INSERT INTO polls (id, title, greeting, creator, image, option_a, option_b)
            VALUES
                ('cats-dogs', 'Do you like this Cat? (Cats vs Dogs)', 'Hi Faza!', 'Momon', '/static/images/cat.jpg', 'Cats', 'Dogs'),
                ('vintage-car', 'Do you like this Classic Beetle Car?', 'Hi Guys!', 'Aarjav', '/static/images/car.jpg', 'Yes!', 'No!'),
                ('coffee-tea', 'Morning Fuel: Coffee or Tea?', 'Good Morning!', 'Nola', 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd?w=800&q=80', 'Coffee ☕', 'Tea 🍵')
            ON CONFLICT (id) DO NOTHING;
        """)
        conn.commit()
    logger.info("Database schema initialized and verified.")


def ensure_stream_group(r: redis.Redis):
    try:
        r.xgroup_create(STREAM_KEY, GROUP_NAME, id='0', mkstream=True)
        logger.info("Created consumer group '%s' on stream '%s'.", GROUP_NAME, STREAM_KEY)
    except redis.exceptions.ResponseError as err:
        if "BUSYGROUP" in str(err):
            pass  # Group already exists
        else:
            logger.warning("Error creating stream consumer group: %s", err)


def persist_vote(conn, voter_id: str, poll_id: str, vote: str, vote_time_iso: Optional[str]) -> bool:
    if not vote_time_iso:
        vote_time = datetime.datetime.now(datetime.timezone.utc)
    else:
        try:
            vote_time = datetime.datetime.fromisoformat(vote_time_iso)
        except Exception:
            vote_time = datetime.datetime.now(datetime.timezone.utc)

    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO votes (id, poll_id, vote, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (id, poll_id)
            DO UPDATE SET
                vote = EXCLUDED.vote,
                updated_at = EXCLUDED.updated_at
            WHERE votes.updated_at <= EXCLUDED.updated_at;
        """, (voter_id, poll_id, vote, vote_time, vote_time))
    conn.commit()
    return True


def process_vote_message(conn, raw_data: Dict[str, Any]) -> bool:
    voter_id = raw_data.get('voter_id', '').strip()
    poll_id = raw_data.get('poll_id', 'cats-dogs').strip()
    vote = raw_data.get('vote', '').strip()
    vote_time = raw_data.get('timestamp')

    if not voter_id or not vote or vote not in ('a', 'b'):
        logger.warning("Discarding invalid vote payload: %s", raw_data)
        return False

    # Extract W3C Trace Context if OpenTelemetry is enabled
    context = None
    if OTEL_ENABLED and tracer:
        carrier = {
            'traceparent': raw_data.get('traceparent', ''),
            'tracestate': raw_data.get('tracestate', '')
        }
        if carrier['traceparent']:
            from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
            context = TraceContextTextMapPropagator().extract(carrier)

    if OTEL_ENABLED and tracer:
        with tracer.start_as_current_span("worker_persist_vote", context=context) as span:
            span.set_attribute("poll.id", poll_id)
            span.set_attribute("vote.choice", vote)
            span.set_attribute("db.system", "postgresql")
            return persist_vote(conn, voter_id, poll_id, vote, vote_time)
    else:
        return persist_vote(conn, voter_id, poll_id, vote, vote_time)


def drain_legacy_queue(r: redis.Redis, conn):
    """
    Safely drains legacy list-based queue messages without message loss.
    Migrates any pending list items directly into PostgreSQL.
    """
    try:
        # Check any stranded worker-specific processing lists from Round 2
        for proc_key in r.scan_iter("votes_processing*"):
            while True:
                item = r.rpop(proc_key)
                if not item:
                    break
                try:
                    data = json.loads(item)
                    process_vote_message(conn, data)
                    logger.info("Migrated stranded vote from %s for voter %s", proc_key, data.get('voter_id'))
                except Exception as ex:
                    logger.error("Error migrating stranded message from %s: %s", proc_key, ex)

        # Drain standard votes list
        count = 0
        while True:
            item = r.rpop(LEGACY_QUEUE_KEY)
            if not item:
                break
            try:
                data = json.loads(item)
                process_vote_message(conn, data)
                count += 1
            except Exception as ex:
                logger.error("Error processing legacy list item: %s", ex)
        if count > 0:
            logger.info("Drained and processed %d legacy votes from list '%s'.", count, LEGACY_QUEUE_KEY)
    except Exception as ex:
        logger.warning("Legacy queue drain error: %s", ex)


def run_worker():
    consumer_name = f"worker_{socket.gethostname()}_{uuid.uuid4().hex[:6]}"
    logger.info("Starting Python Votex Worker daemon (Consumer: %s)...", consumer_name)

    conn = get_db_connection()
    if not conn:
        logger.error("Could not obtain DB connection on startup.")
        sys.exit(1)

    init_database_schema(conn)

    r = get_redis_client()
    if not r:
        logger.error("Could not obtain Redis connection on startup.")
        sys.exit(1)

    ensure_stream_group(r)

    # Initial migration of any residual list-based messages
    drain_legacy_queue(r, conn)

    last_autoclaim = 0.0

    while running:
        try:
            now = time.time()

            # 1. Periodically auto-claim abandoned messages from crashed / replaced pods
            if now - last_autoclaim >= AUTOCLAIM_INTERVAL_SEC:
                last_autoclaim = now
                try:
                    # XAUTOCLAIM claims pending messages idle for > AUTOCLAIM_IDLE_MS
                    claim_res = r.xautoclaim(
                        STREAM_KEY,
                        GROUP_NAME,
                        consumer_name,
                        min_idle_time=AUTOCLAIM_IDLE_MS,
                        start_id='0-0',
                        count=10
                    )
                    # claim_res format: [next_start_id, [ (msg_id, {fields...}), ... ], [deleted_ids...]]
                    if claim_res and len(claim_res) >= 2 and claim_res[1]:
                        for msg_id, fields in claim_res[1]:
                            logger.info("Claimed abandoned message %s from stream.", msg_id)
                            success = process_vote_message(conn, fields)
                            if success:
                                r.xack(STREAM_KEY, GROUP_NAME, msg_id)
                except Exception as claim_err:
                    logger.warning("XAUTOCLAIM error: %s", claim_err)

            # 2. Check for legacy list items if any were enqueued
            drain_legacy_queue(r, conn)

            # 3. Read new messages assigned to this consumer
            entries = r.xreadgroup(
                GROUP_NAME,
                consumer_name,
                {STREAM_KEY: '>'},
                count=10,
                block=1000
            )

            if entries:
                for stream_name, messages in entries:
                    for msg_id, fields in messages:
                        try:
                            success = process_vote_message(conn, fields)
                            if success:
                                # Acknowledge message only after DB commit
                                r.xack(STREAM_KEY, GROUP_NAME, msg_id)
                        except (psycopg2.OperationalError, psycopg2.InterfaceError) as db_conn_err:
                            logger.error("DB connection error during vote processing: %s. Reconnecting...", db_conn_err)
                            try:
                                conn.close()
                            except Exception:
                                pass
                            conn = get_db_connection()
                            # Do NOT ack; message remains pending in PEL for retry or autoclaim
                        except Exception as msg_err:
                            logger.error("Unexpected error processing message %s: %s", msg_id, msg_err)
            else:
                # Idle tick
                time.sleep(0.05)

        except redis.exceptions.ConnectionError:
            logger.warning("Redis connection lost. Reconnecting...")
            r = get_redis_client()
            if r:
                ensure_stream_group(r)
        except Exception as loop_ex:
            logger.error("Worker loop exception: %s", loop_ex)
            time.sleep(1)

    logger.info("Worker shutting down cleanly.")
    try:
        if conn:
            conn.close()
    except Exception:
        pass


if __name__ == '__main__':
    run_worker()

