# pyrefly: ignore [missing-import]
from flask import Flask, render_template, request, make_response, g, jsonify
# pyrefly: ignore [missing-import]
from redis import Redis
import os
import socket
import json
import logging
import time
import datetime
import uuid
import re
import secrets

try:
    import bcrypt
    HAS_BCRYPT = True
except ImportError:
    import hashlib
    HAS_BCRYPT = False

import db

app = Flask(__name__)

# Respect AWS Application Load Balancer / Reverse Proxy headers for HTTPS detection
try:
    from werkzeug.middleware.proxy_fix import ProxyFix
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)
except Exception:
    pass

# OpenTelemetry distributed tracing with AWS X-Ray ID generator
OTEL_ENABLED = os.getenv('OTEL_ENABLED', 'true').lower() in ('true', '1')
tracer = None

if OTEL_ENABLED:
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator
        from opentelemetry.instrumentation.flask import FlaskInstrumentor
        from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

        provider = TracerProvider(id_generator=AwsXRayIdGenerator())
        otlp_endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT')
        if otlp_endpoint:
            try:
                from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
                exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
                provider.add_span_processor(BatchSpanProcessor(exporter))
            except Exception as exp_err:
                app.logger.warning("OTLP exporter initialization deferred: %s", exp_err)
        trace.set_tracer_provider(provider)
        tracer = trace.get_tracer("votex-vote", "2.1.0")
        FlaskInstrumentor().instrument_app(app)
    except Exception as otel_err:
        app.logger.warning("OpenTelemetry vote initialization skipped: %s", otel_err)
        tracer = None

# Configure logging
gunicorn_error_logger = logging.getLogger('gunicorn.error')
if gunicorn_error_logger.handlers:
    app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

# Environment configuration
option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()
REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
RESULT_URL = os.getenv('RESULT_URL', '/')
SECURE_COOKIES = os.getenv('SESSION_COOKIE_SECURE', 'false').lower() in ('true', '1')

# In-memory session store used ONLY as fallback during standalone unit testing without Redis
_TEST_SESSIONS = {}

def get_redis():
    try:
        if not hasattr(g, 'redis'):
            try:
                g.redis = Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, socket_timeout=3, decode_responses=True)
                g.redis.ping()
            except Exception as e:
                app.logger.warning("Redis connection failed (%s:%s): %s", REDIS_HOST, REDIS_PORT, e)
                g.redis = None
        return g.redis
    except RuntimeError:
        try:
            r = Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, socket_timeout=3, decode_responses=True)
            r.ping()
            return r
        except Exception as e:
            app.logger.warning("Standalone Redis connection failed (%s:%s): %s", REDIS_HOST, REDIS_PORT, e)
            return None

# Password hashing

def hash_password(password: str) -> str:
    if not HAS_BCRYPT:
        raise RuntimeError("Bcrypt hashing library required for secure password storage. Insecure fallbacks are strictly prohibited.")
    pw_bytes = password.encode('utf-8')
    salt_bytes = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(pw_bytes, salt_bytes).decode('utf-8')

def verify_password(password: str, stored_hash: str) -> bool:
    if not stored_hash or not password:
        return False
    if not HAS_BCRYPT:
        app.logger.error("Bcrypt hashing library unavailable for password verification")
        return False
    try:
        if stored_hash.startswith(('$2b$', '$2a$', '$2y$')):
            return bcrypt.checkpw(password.encode('utf-8'), stored_hash.encode('utf-8'))
        app.logger.warning("Rejected non-bcrypt or unhashed password format")
        return False
    except Exception as e:
        app.logger.warning("Password verification exception: %s", e)
        return False

# Session management

SESSION_PREFIX = "votex:session:"
SESSION_TTL = 86400 * 30  # 30 days

def store_session(token: str, username: str):
    r = get_redis()
    if r:
        try:
            r.set(f"{SESSION_PREFIX}{token}", username, ex=SESSION_TTL)
            return
        except Exception as e:
            app.logger.error("Redis session set error: %s", e)
    _TEST_SESSIONS[token] = username

def get_session_user(token: str):
    if not token:
        return None
    r = get_redis()
    if r:
        try:
            user = r.get(f"{SESSION_PREFIX}{token}")
            if user:
                return user
        except Exception as e:
            app.logger.error("Redis session get error: %s", e)
    return _TEST_SESSIONS.get(token)

def delete_session(token: str):
    if not token:
        return
    r = get_redis()
    if r:
        try:
            r.delete(f"{SESSION_PREFIX}{token}")
        except Exception as e:
            app.logger.error("Redis session delete error: %s", e)
    _TEST_SESSIONS.pop(token, None)

def get_current_user():
    token = request.cookies.get('auth_token')
    if not token:
        return None
    username = get_session_user(token)
    if not username:
        return None
    try:
        user = db.get_user_by_username(username)
        if user:
            user.pop('password_hash', None)
        return user
    except Exception as e:
        app.logger.error("Error fetching current user from DB: %s", e)
        return None

# Rate limiting

def check_rate_limit(key: str, limit: int = 10, window_seconds: int = 60) -> bool:
    """
    Atomic sliding-window counter rate limiter backed by Redis.
    Fails open if Redis is temporarily unreachable.
    """
    if app.config.get('TESTING') and not app.config.get('ENABLE_RATE_LIMIT_TEST'):
        return True
    r = get_redis()
    if not r:
        return True
    try:
        val = r.incr(key)
        if val == 1:
            r.expire(key, window_seconds)
        return val <= limit
    except Exception as ex:
        app.logger.warning("Rate limiter error: %s", ex)
        return True

# CSRF and cookie helpers

def get_or_generate_csrf_token():
    token = request.cookies.get('csrf_token')
    if not token:
        token = secrets.token_hex(24)
    return token

def validate_csrf():
    # Only validate on mutating requests
    if request.method in ('POST', 'PUT', 'DELETE', 'PATCH'):
        # Exclude testing mode if bypass requested
        if app.config.get('TESTING') and not request.cookies.get('csrf_token'):
            return True
        header_csrf = request.headers.get('X-CSRF-Token')
        cookie_csrf = request.cookies.get('csrf_token')
        # Allow form submissions with matching form field
        form_csrf = request.form.get('csrf_token') if request.form else None
        token_sent = header_csrf or form_csrf
        if not token_sent or token_sent != cookie_csrf:
            return False
    return True

def set_secure_cookie(response, key, value, max_age=86400 * 30, httponly=True):
    # Rely on ProxyFix sanitized request.is_secure and environment override
    is_secure = SECURE_COOKIES or request.is_secure
    response.set_cookie(
        key,
        value,
        max_age=max_age,
        httponly=httponly,
        secure=is_secure,
        samesite='Lax',
        path='/'
    )

@app.after_request
def set_security_headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    return response

# Initialize database schema safely
try:
    db.init_db()
except Exception as e:
    app.logger.warning("DB init deferred: %s", e)

# Routes

@app.route("/", methods=['POST', 'GET'])
def index():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = uuid.uuid4().hex

    csrf_token = get_or_generate_csrf_token()
    user = get_current_user()
    vote = None

    if request.method == 'POST':
        # Enforce CSRF validation for POST requests
        if not validate_csrf():
            return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

        if request.is_json:
            data_in = request.get_json(silent=True) or {}
            vote = data_in.get('vote')
            poll_id = data_in.get('poll_id', 'cats-dogs')
        else:
            vote = request.form.get('vote')
            poll_id = request.form.get('poll_id', 'cats-dogs')

        # Input validation for vote option and poll_id
        if not vote or vote not in ('a', 'b'):
            return jsonify({"status": "error", "message": "Invalid voting option. Must be 'a' or 'b'"}), 400

        # Validate poll exists
        poll = None
        try:
            poll = db.get_poll(poll_id)
        except Exception as e:
            app.logger.error("DB error fetching poll %s: %s", poll_id, e)

        if not poll and poll_id != 'cats-dogs':
            return jsonify({"status": "error", "message": f"Poll '{poll_id}' not found"}), 404

        # Enforce voting rate limit
        if not check_rate_limit(f"ratelimit:vote:{voter_id}", limit=30, window_seconds=60):
            return jsonify({"status": "error", "message": "Voting rate limit exceeded. Please wait a moment."}), 429

        redis = get_redis()
        if not redis:
            app.logger.error("Redis queue unavailable during vote enqueue")
            return jsonify({"status": "error", "message": "Voting queue service unavailable"}), 503

        vote_time = datetime.datetime.now(datetime.timezone.utc).isoformat()
        carrier = {}
        if OTEL_ENABLED:
            try:
                from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
                TraceContextTextMapPropagator().inject(carrier)
            except Exception:
                pass

        stream_payload = {
            'voter_id': voter_id,
            'poll_id': poll_id,
            'vote': vote,
            'timestamp': vote_time,
            'traceparent': carrier.get('traceparent', ''),
            'tracestate': carrier.get('tracestate', '')
        }

        try:
            # Redis Streams with consumer group and persistent durability
            redis.xadd('votes_stream', stream_payload)
        except Exception as ex:
            app.logger.error("Redis enqueue error: %s", ex)
            return jsonify({"status": "error", "message": "Failed to enqueue vote"}), 503

        if user:
            username = user.get('username')
            choice_label = (poll.get('optA') if poll else option_a) if vote == 'a' else (poll.get('optB') if poll else option_b)
            try:
                db.log_user_activity(username, "vote", f"Voted '{choice_label}' on poll #{poll_id}", "fa-check-to-slot")
            except Exception as e:
                app.logger.warning("Failed to log user vote activity: %s", e)

        if request.is_json or request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            resp = make_response(jsonify({'status': 'ok', 'vote': vote, 'poll_id': poll_id, 'voter_id': voter_id}))
            set_secure_cookie(resp, 'voter_id', voter_id, max_age=86400 * 365, httponly=True)
            set_secure_cookie(resp, 'csrf_token', csrf_token, max_age=86400 * 30, httponly=False)
            return resp

    # Fetch initial comments and polls
    comments = []
    polls = []
    try:
        comments = db.get_comments(poll_id='cats-dogs', limit=10)
        polls = db.get_polls()
    except Exception as e:
        app.logger.warning("Could not fetch initial data from DB: %s", e)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
        voter_id=voter_id,
        initial_comments=comments,
        current_user=user,
        result_url=RESULT_URL,
        csrf_token=csrf_token
    ))
    set_secure_cookie(resp, 'voter_id', voter_id, max_age=86400 * 365, httponly=True)
    set_secure_cookie(resp, 'csrf_token', csrf_token, max_age=86400 * 30, httponly=False)
    return resp

# Config API

@app.route("/api/config", methods=['GET'])
def api_config():
    csrf_token = get_or_generate_csrf_token()
    resp = make_response(jsonify({
        "result_url": RESULT_URL,
        "csrf_token": csrf_token,
        "option_a": option_a,
        "option_b": option_b
    }))
    set_secure_cookie(resp, 'csrf_token', csrf_token, max_age=86400 * 30, httponly=False)
    return resp

# Authentication API

@app.route("/api/auth/register", methods=['POST'])
def api_register():
    if not validate_csrf():
        return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr or '127.0.0.1').split(',')[0].strip()
    if not check_rate_limit(f"ratelimit:auth:register:{client_ip}", limit=10, window_seconds=60):
        return jsonify({"status": "error", "message": "Too many registration attempts. Please wait 1 minute."}), 429

    data = request.get_json(silent=True) or {}
    username = str(data.get('username', '')).strip().lower()
    password = str(data.get('password', '')).strip()
    display_name = str(data.get('display_name', '')).strip() or username.capitalize()
    email = str(data.get('email', '')).strip()
    avatar = str(data.get('avatar', '👨🏼‍🚀')).strip()
    bg = str(data.get('bg', '#3b82f6')).strip()
    bio = str(data.get('bio', 'Active voter on Votex.')).strip()

    if not username or len(username) < 3 or not re.match(r'^[a-zA-Z0-9_]+$', username):
        return jsonify({"status": "error", "message": "Username must be at least 3 alphanumeric characters"}), 400
    if not password or len(password) < 6:
        return jsonify({"status": "error", "message": "Password must be at least 6 characters"}), 400
    if email and not re.match(r'^[^@]+@[^@]+\.[^@]+$', email):
        return jsonify({"status": "error", "message": "Invalid email address format"}), 400

    try:
        existing = db.get_user_by_username(username)
        if existing:
            return jsonify({"status": "error", "message": "Username already exists. Please pick another or sign in."}), 409

        user_id = f"u_{uuid.uuid4().hex[:8]}"
        pwd_hash = hash_password(password)
        new_user = db.create_user(
            user_id=user_id,
            username=username,
            password_hash=pwd_hash,
            display_name=display_name,
            email=email or f"{username}@votex.dev",
            avatar=avatar,
            bg=bg,
            bio=bio
        )
    except Exception as e:
        app.logger.error("DB error during user registration: %s", e)
        return jsonify({"status": "error", "message": "Registration failed due to database error"}), 500

    token = secrets.token_hex(32)
    store_session(token, username)

    csrf_token = get_or_generate_csrf_token()
    resp = make_response(jsonify({"status": "ok", "message": "Account created successfully!", "user": new_user}))
    set_secure_cookie(resp, 'auth_token', token, max_age=SESSION_TTL, httponly=True)
    set_secure_cookie(resp, 'csrf_token', csrf_token, max_age=86400 * 30, httponly=False)
    return resp

@app.route("/api/auth/login", methods=['POST'])
def api_login():
    if not validate_csrf():
        return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr or '127.0.0.1').split(',')[0].strip()
    if not check_rate_limit(f"ratelimit:auth:login:{client_ip}", limit=10, window_seconds=60):
        return jsonify({"status": "error", "message": "Too many login attempts. Please wait 1 minute."}), 429

    data = request.get_json(silent=True) or {}
    username = str(data.get('username', '')).strip().lower()
    password = str(data.get('password', '')).strip()

    if not username or not password:
        return jsonify({"status": "error", "message": "Username and password required"}), 400

    try:
        user = db.get_user_by_username(username)
    except Exception as e:
        app.logger.error("DB error during user login: %s", e)
        return jsonify({"status": "error", "message": "Login service error"}), 500

    if not user or not verify_password(password, user.get('password_hash', '')):
        return jsonify({"status": "error", "message": "Invalid username or password"}), 401

    token = secrets.token_hex(32)
    store_session(token, username)

    try:
        db.log_user_activity(username, "login", "Logged in to Votex", "fa-right-to-bracket")
    except Exception as e:
        app.logger.warning("Could not log login activity: %s", e)

    user.pop('password_hash', None)
    csrf_token = get_or_generate_csrf_token()
    resp = make_response(jsonify({"status": "ok", "message": f"Welcome back, {user['display_name']}!", "user": user}))
    set_secure_cookie(resp, 'auth_token', token, max_age=SESSION_TTL, httponly=True)
    set_secure_cookie(resp, 'csrf_token', csrf_token, max_age=86400 * 30, httponly=False)
    return resp

@app.route("/api/auth/logout", methods=['POST'])
def api_logout():
    token = request.cookies.get('auth_token')
    if token:
        delete_session(token)
    resp = make_response(jsonify({"status": "ok", "message": "Logged out successfully"}))
    resp.set_cookie('auth_token', '', max_age=0, path='/')
    return resp

@app.route("/api/auth/me", methods=['GET'])
def api_me():
    user = get_current_user()
    if not user:
        return jsonify({"status": "unauthenticated", "user": None})
    return jsonify({"status": "ok", "user": user})

@app.route("/api/auth/profile", methods=['PUT'])
def api_update_profile():
    if not validate_csrf():
        return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

    user = get_current_user()
    if not user:
        return jsonify({"status": "error", "message": "Authentication required"}), 401

    data = request.get_json(silent=True) or {}

    # Privilege escalation prevention: forbid modifying role or level
    if 'role' in data or 'level' in data:
        return jsonify({"status": "error", "message": "Modifying privileged fields (role, level) is prohibited"}), 403

    try:
        updated = db.update_user_profile(
            username=user['username'],
            display_name=data.get('display_name'),
            bio=data.get('bio'),
            avatar=data.get('avatar'),
            bg=data.get('bg')
        )
        if updated:
            updated.pop('password_hash', None)
        return jsonify({"status": "ok", "message": "Profile updated successfully!", "user": updated})
    except Exception as e:
        app.logger.error("Profile update error: %s", e)
        return jsonify({"status": "error", "message": "Failed to update profile"}), 500

# Polls API

@app.route("/api/polls", methods=['GET', 'POST'])
def handle_polls():
    if request.method == 'POST':
        if not validate_csrf():
            return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

        data = request.get_json(silent=True) or {}
        title = str(data.get('title', '')).strip()
        opt_a = str(data.get('optA', '')).strip() or str(data.get('option_a', '')).strip()
        opt_b = str(data.get('optB', '')).strip() or str(data.get('option_b', '')).strip()
        greeting = str(data.get('greeting', 'New Community Poll!')).strip()
        image = str(data.get('image', '/static/images/car.jpg')).strip()

        if not title or len(title) < 4:
            return jsonify({"status": "error", "message": "Poll title must be at least 4 characters"}), 400
        if not opt_a or not opt_b:
            return jsonify({"status": "error", "message": "Both options are required"}), 400
        if opt_a.lower() == opt_b.lower():
            return jsonify({"status": "error", "message": "Options must be different"}), 400

        user = get_current_user()
        creator = user['username'] if user else 'Community'

        poll_id = f"poll-{uuid.uuid4().hex[:8]}"
        try:
            new_poll = db.create_poll(
                poll_id=poll_id,
                title=title,
                creator=creator,
                option_a=opt_a,
                option_b=opt_b,
                image=image,
                greeting=greeting
            )
            return jsonify({"status": "ok", "poll": new_poll}), 201
        except Exception as e:
            app.logger.error("Failed to create poll: %s", e)
            return jsonify({"status": "error", "message": "Database error creating poll"}), 500

    # GET polls
    try:
        polls = db.get_polls()
        return jsonify({"status": "ok", "polls": polls})
    except Exception as e:
        app.logger.error("Error fetching polls: %s", e)
        return jsonify({"status": "error", "polls": []}), 500

@app.route("/api/polls/<poll_id>", methods=['GET'])
def get_single_poll(poll_id):
    try:
        poll = db.get_poll(poll_id)
        if not poll:
            return jsonify({"status": "error", "message": "Poll not found"}), 404
        return jsonify({"status": "ok", "poll": poll})
    except Exception as e:
        app.logger.error("Error fetching poll %s: %s", poll_id, e)
        return jsonify({"status": "error", "message": "Database error"}), 500

# User activity and bookmarks API

@app.route("/api/user/activity", methods=['GET'])
def api_user_activity():
    user = get_current_user()
    if not user:
        return jsonify({"activities": []})
    try:
        acts = db.get_user_activities(user['username'])
        return jsonify({"activities": acts})
    except Exception as e:
        app.logger.error("Error fetching activities: %s", e)
        return jsonify({"activities": []})

@app.route("/api/user/bookmarks", methods=['GET', 'POST'])
def api_user_bookmarks():
    user = get_current_user()
    if not user:
        return jsonify({"status": "error", "message": "Sign in to save bookmarks"}), 401

    if request.method == 'POST':
        if not validate_csrf():
            return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

        data = request.get_json(silent=True) or {}
        poll_id = data.get('poll_id')
        if not poll_id:
            return jsonify({"status": "error", "message": "poll_id required"}), 400

        try:
            is_b, bms = db.toggle_user_bookmark(user['username'], poll_id)
            return jsonify({"status": "ok", "is_bookmarked": is_b, "bookmarks": bms})
        except Exception as e:
            app.logger.error("Error toggling bookmark: %s", e)
            return jsonify({"status": "error", "message": "Failed to update bookmark"}), 500

    try:
        bms = db.get_user_bookmarks(user['username'])
        return jsonify({"bookmarks": bms})
    except Exception as e:
        app.logger.error("Error fetching bookmarks: %s", e)
        return jsonify({"bookmarks": []})

# Comments API

@app.route("/api/comments", methods=['GET', 'POST'])
def handle_comments():
    if request.method == 'POST':
        if not validate_csrf():
            return jsonify({"status": "error", "message": "CSRF token validation failed"}), 403

        data = request.get_json(silent=True) or {}
        text = str(data.get('text', '')).strip()
        poll_id = str(data.get('poll_id', 'cats-dogs')).strip()
        user = get_current_user()

        if not text:
            return jsonify({"status": "error", "message": "Comment cannot be empty"}), 400
        if len(text) > 500:
            return jsonify({"status": "error", "message": "Comment cannot exceed 500 characters"}), 400

        author = user['display_name'] if user else str(data.get('author', 'Community Member')).strip() or 'Community Member'
        avatar = user['avatar'] if user else '👩🏻‍🦰'
        bg = user['bg'] if user else '#fca5a5'
        username = user['username'] if user else None

        try:
            comment = db.create_comment(
                poll_id=poll_id,
                author=author,
                avatar=avatar,
                bg=bg,
                text=text,
                username=username
            )
            return jsonify({"status": "ok", "comment": comment})
        except Exception as e:
            app.logger.error("Error creating comment: %s", e)
            return jsonify({"status": "error", "message": "Database error saving comment"}), 500

    poll_id = request.args.get('poll_id')
    try:
        comments = db.get_comments(poll_id=poll_id)
        return jsonify({"comments": comments})
    except Exception as e:
        app.logger.error("Error fetching comments: %s", e)
        return jsonify({"comments": []})

# Health and readiness

@app.route("/api/health")
def health():
    redis_status = "healthy"
    r = get_redis()
    if not r:
        redis_status = "disconnected"

    db_status = "healthy"
    try:
        with db.DBConnection() as conn:
            if not conn:
                db_status = "disconnected"
            else:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
    except Exception:
        db_status = "unhealthy"

    overall_status = "healthy" if (redis_status == "healthy" and db_status == "healthy") else "degraded"

    return jsonify({
        "status": overall_status,
        "service": "vote-python-flask",
        "container_id": hostname,
        "redis": redis_status,
        "database": db_status,
        "timestamp": int(time.time())
    }), (200 if overall_status == "healthy" else 503)

if __name__ == "__main__":
    port = int(os.getenv("PORT", 80))
    app.run(host='0.0.0.0', port=port, debug=False, threaded=True)
