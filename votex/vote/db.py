import os
import logging
import psycopg2
from psycopg2 import pool, extras

logger = logging.getLogger(__name__)

_pool = None

def get_db_config():
    db_url = os.getenv('DATABASE_URL')
    if db_url:
        return {'dsn': db_url}
    return {
        'host': os.getenv('POSTGRES_HOST', 'localhost'),
        'port': int(os.getenv('POSTGRES_PORT', 5432)),
        'user': os.getenv('POSTGRES_USER', 'postgres'),
        'password': os.getenv('POSTGRES_PASSWORD', ''),
        'dbname': os.getenv('POSTGRES_DB', 'postgres'),
        'connect_timeout': 5
    }

def get_connection_pool():
    global _pool
    if _pool is None:
        try:
            cfg = get_db_config()
            if 'dsn' in cfg:
                _pool = psycopg2.pool.ThreadedConnectionPool(1, 20, dsn=cfg['dsn'])
            else:
                _pool = psycopg2.pool.ThreadedConnectionPool(
                    1, 20,
                    host=cfg['host'],
                    port=cfg['port'],
                    user=cfg['user'],
                    password=cfg['password'],
                    dbname=cfg['dbname'],
                    connect_timeout=cfg['connect_timeout']
                )
        except Exception as e:
            logger.warning("Could not establish PostgreSQL connection pool: %s", e)
            _pool = None
    return _pool

class DBConnection:
    def __init__(self):
        self.conn = None
        self.p = get_connection_pool()

    def __enter__(self):
        if self.p:
            try:
                self.conn = self.p.getconn()
                return self.conn
            except Exception as e:
                logger.error("Failed to acquire DB connection from pool: %s", e)
        # Direct fallback connection if pool failed
        try:
            cfg = get_db_config()
            if 'dsn' in cfg:
                self.conn = psycopg2.connect(dsn=cfg['dsn'])
            else:
                self.conn = psycopg2.connect(
                    host=cfg['host'],
                    port=cfg['port'],
                    user=cfg['user'],
                    password=cfg['password'],
                    dbname=cfg['dbname'],
                    connect_timeout=cfg['connect_timeout']
                )
            return self.conn
        except Exception as ex:
            logger.error("Direct DB connection failed: %s", ex)
            return None

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.conn:
            if exc_type is not None:
                try:
                    self.conn.rollback()
                except Exception:
                    pass
            if self.p:
                try:
                    self.p.putconn(self.conn)
                except Exception:
                    pass
            else:
                try:
                    self.conn.close()
                except Exception:
                    pass

def init_db():
    with DBConnection() as conn:
        if not conn:
            logger.warning("Skipping DB init: database connection unavailable")
            return False
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

            CREATE TABLE IF NOT EXISTS users (
                id VARCHAR(64) PRIMARY KEY,
                username VARCHAR(64) UNIQUE NOT NULL,
                password_hash VARCHAR(255) NOT NULL,
                display_name VARCHAR(128) NOT NULL,
                email VARCHAR(255),
                avatar VARCHAR(32) DEFAULT '👨🏼‍🚀',
                bg VARCHAR(32) DEFAULT '#3b82f6',
                role VARCHAR(64) DEFAULT 'Community Voter',
                bio TEXT DEFAULT '',
                level VARCHAR(64) DEFAULT 'Level 1 Explorer',
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS votes (
                id VARCHAR(255) NOT NULL,
                poll_id VARCHAR(64) NOT NULL DEFAULT 'cats-dogs' REFERENCES polls(id) ON DELETE CASCADE,
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

            CREATE TABLE IF NOT EXISTS comments (
                id BIGSERIAL PRIMARY KEY,
                poll_id VARCHAR(64) NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
                author VARCHAR(128) NOT NULL,
                avatar VARCHAR(32) DEFAULT '👩🏻‍🦰',
                bg VARCHAR(32) DEFAULT '#fca5a5',
                text TEXT NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS bookmarks (
                username VARCHAR(64) NOT NULL REFERENCES users(username) ON DELETE CASCADE,
                poll_id VARCHAR(64) NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (username, poll_id)
            );

            CREATE TABLE IF NOT EXISTS user_activities (
                id BIGSERIAL PRIMARY KEY,
                username VARCHAR(64) NOT NULL REFERENCES users(username) ON DELETE CASCADE,
                activity_type VARCHAR(64) NOT NULL,
                title VARCHAR(255) NOT NULL,
                icon VARCHAR(64) DEFAULT 'fa-bolt',
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );

            CREATE INDEX IF NOT EXISTS idx_votes_poll_vote ON votes(poll_id, vote);
            CREATE INDEX IF NOT EXISTS idx_votes_updated ON votes(updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_comments_poll ON comments(poll_id);
            CREATE INDEX IF NOT EXISTS idx_activities_user ON user_activities(username, created_at DESC);
            """)

            # Seed default polls if none exist
            cur.execute("""
            INSERT INTO polls (id, title, greeting, creator, image, option_a, option_b)
            VALUES
                ('cats-dogs', 'Do you like this Cat? (Cats vs Dogs)', 'Hi Faza!', 'Momon', '/static/images/cat.jpg', 'Cats', 'Dogs'),
                ('vintage-car', 'Do you like this Classic Beetle Car?', 'Hi Guys!', 'Aarjav', '/static/images/car.jpg', 'Yes!', 'No!'),
                ('coffee-tea', 'Morning Fuel: Coffee or Tea?', 'Good Morning!', 'Nola', 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd?w=800&q=80', 'Coffee ☕', 'Tea 🍵')
            ON CONFLICT (id) DO NOTHING;
            """)
            conn.commit()
            logger.info("Database schema initialized and verified.")
            return True

# Users

def get_user_by_username(username: str):
    if not username:
        return None
    with DBConnection() as conn:
        if not conn:
            return None
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, username, password_hash, display_name, email, avatar, bg, role, bio, level,
                       TO_CHAR(created_at, 'YYYY-MM-DD') as created_at
                FROM users WHERE username = %s
            """, (username.strip().lower(),))
            user = cur.fetchone()
            if not user:
                return None

            # Fetch user bookmarks
            cur.execute("SELECT poll_id FROM bookmarks WHERE username = %s", (username,))
            user['bookmarks'] = [r['poll_id'] for r in cur.fetchall()]

            # Fetch counts
            cur.execute("SELECT COUNT(*) as count FROM votes WHERE id = %s", (user['id'],))
            vote_row = cur.fetchone()
            user['votes_count'] = vote_row['count'] if vote_row else 0

            cur.execute("SELECT COUNT(*) as count FROM polls WHERE creator = %s", (user['username'],))
            poll_row = cur.fetchone()
            user['polls_count'] = poll_row['count'] if poll_row else 0

            cur.execute("SELECT COUNT(*) as count FROM comments WHERE author = %s", (user['display_name'],))
            comm_row = cur.fetchone()
            user['comments_count'] = comm_row['count'] if comm_row else 0

            return dict(user)

def create_user(user_id: str, username: str, password_hash: str, display_name: str,
                email: str = None, avatar: str = '👨🏼‍🚀', bg: str = '#3b82f6', bio: str = ''):
    with DBConnection() as conn:
        if not conn:
            raise RuntimeError("Database unavailable")
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                INSERT INTO users (id, username, password_hash, display_name, email, avatar, bg, bio, role, level)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'Community Voter', 'Level 1 Explorer')
                RETURNING id, username, display_name, email, avatar, bg, role, bio, level,
                          TO_CHAR(created_at, 'YYYY-MM-DD') as created_at
            """, (user_id, username.strip().lower(), password_hash, display_name.strip(),
                  email, avatar, bg, bio))
            new_user = dict(cur.fetchone())
            new_user['bookmarks'] = []
            new_user['votes_count'] = 0
            new_user['polls_count'] = 0
            new_user['comments_count'] = 0

            # Log system activity
            cur.execute("""
                INSERT INTO user_activities (username, activity_type, title, icon)
                VALUES (%s, 'system', 'Created account and joined Votex', 'fa-sparkles')
            """, (username.strip().lower(),))
            conn.commit()
            return new_user

def update_user_profile(username: str, display_name: str = None, bio: str = None,
                        avatar: str = None, bg: str = None):
    # Notice: Role and level are NEVER updated here (privilege escalation protection)
    with DBConnection() as conn:
        if not conn:
            raise RuntimeError("Database unavailable")
        with conn.cursor() as cur:
            updates = []
            params = []
            if display_name is not None and display_name.strip():
                updates.append("display_name = %s")
                params.append(display_name.strip())
            if bio is not None:
                updates.append("bio = %s")
                params.append(bio.strip())
            if avatar is not None and avatar.strip():
                updates.append("avatar = %s")
                params.append(avatar.strip())
            if bg is not None and bg.strip():
                updates.append("bg = %s")
                params.append(bg.strip())

            if not updates:
                return get_user_by_username(username)

            params.append(username.strip().lower())
            query = f"UPDATE users SET {', '.join(updates)} WHERE username = %s"
            cur.execute(query, tuple(params))

            cur.execute("""
                INSERT INTO user_activities (username, activity_type, title, icon)
                VALUES (%s, 'profile_update', 'Updated profile settings', 'fa-user-pen')
            """, (username.strip().lower(),))
            conn.commit()
            return get_user_by_username(username)

# Polls

def get_polls():
    with DBConnection() as conn:
        if not conn:
            return []
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, title, greeting, creator, image, option_a as "optA", option_b as "optB",
                       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
                FROM polls ORDER BY created_at ASC
            """)
            return [dict(r) for r in cur.fetchall()]

def get_poll(poll_id: str):
    if not poll_id:
        return None
    with DBConnection() as conn:
        if not conn:
            return None
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, title, greeting, creator, image, option_a as "optA", option_b as "optB",
                       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
                FROM polls WHERE id = %s
            """, (poll_id.strip(),))
            row = cur.fetchone()
            return dict(row) if row else None

def create_poll(poll_id: str, title: str, creator: str, option_a: str, option_b: str,
                image: str = '', greeting: str = 'New Community Poll!'):
    with DBConnection() as conn:
        if not conn:
            raise RuntimeError("Database unavailable")
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                INSERT INTO polls (id, title, greeting, creator, image, option_a, option_b)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING id, title, greeting, creator, image, option_a as "optA", option_b as "optB",
                          TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
            """, (poll_id.strip(), title.strip(), greeting.strip(), creator.strip(), image.strip(),
                  option_a.strip(), option_b.strip()))
            new_poll = dict(cur.fetchone())

            cur.execute("""
                INSERT INTO user_activities (username, activity_type, title, icon)
                VALUES (%s, 'create', %s, 'fa-plus-circle')
            """, (creator.strip().lower(), f"Published poll '{title.strip()}'"))
            conn.commit()
            return new_poll

# Comments

def get_comments(poll_id: str = None, limit: int = 50):
    with DBConnection() as conn:
        if not conn:
            return []
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if poll_id and poll_id != 'all':
                cur.execute("""
                    SELECT id, poll_id, author, avatar, bg, text,
                           TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
                    FROM comments WHERE poll_id = %s
                    ORDER BY created_at DESC LIMIT %s
                """, (poll_id.strip(), limit))
            else:
                cur.execute("""
                    SELECT id, poll_id, author, avatar, bg, text,
                           TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
                    FROM comments ORDER BY created_at DESC LIMIT %s
                """, (limit,))
            return [dict(r) for r in cur.fetchall()]

def create_comment(poll_id: str, author: str, avatar: str, bg: str, text: str, username: str = None):
    with DBConnection() as conn:
        if not conn:
            raise RuntimeError("Database unavailable")
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                INSERT INTO comments (poll_id, author, avatar, bg, text)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id, poll_id, author, avatar, bg, text,
                          TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
            """, (poll_id.strip(), author.strip(), avatar.strip(), bg.strip(), text.strip()))
            comment = dict(cur.fetchone())

            if username:
                cur.execute("""
                    INSERT INTO user_activities (username, activity_type, title, icon)
                    VALUES (%s, 'comment', %s, 'fa-comment')
                """, (username.strip().lower(), f"Posted comment on poll #{poll_id.strip()}"))
            conn.commit()
            return comment

# Bookmarks

def get_user_bookmarks(username: str):
    if not username:
        return []
    with DBConnection() as conn:
        if not conn:
            return []
        with conn.cursor() as cur:
            cur.execute("SELECT poll_id FROM bookmarks WHERE username = %s", (username.strip().lower(),))
            return [r[0] for r in cur.fetchall()]

def toggle_user_bookmark(username: str, poll_id: str):
    if not username or not poll_id:
        return False, []
    with DBConnection() as conn:
        if not conn:
            raise RuntimeError("Database unavailable")
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM bookmarks WHERE username = %s AND poll_id = %s",
                        (username.strip().lower(), poll_id.strip()))
            exists = cur.fetchone()
            if exists:
                cur.execute("DELETE FROM bookmarks WHERE username = %s AND poll_id = %s",
                            (username.strip().lower(), poll_id.strip()))
                is_bookmarked = False
                cur.execute("""
                    INSERT INTO user_activities (username, activity_type, title, icon)
                    VALUES (%s, 'bookmark', %s, 'fa-bookmark')
                """, (username.strip().lower(), f"Removed bookmark for poll #{poll_id.strip()}"))
            else:
                cur.execute("INSERT INTO bookmarks (username, poll_id) VALUES (%s, %s)",
                            (username.strip().lower(), poll_id.strip()))
                is_bookmarked = True
                cur.execute("""
                    INSERT INTO user_activities (username, activity_type, title, icon)
                    VALUES (%s, 'bookmark', %s, 'fa-bookmark')
                """, (username.strip().lower(), f"Bookmarked poll #{poll_id.strip()}"))
            conn.commit()

            cur.execute("SELECT poll_id FROM bookmarks WHERE username = %s", (username.strip().lower(),))
            bookmarks = [r[0] for r in cur.fetchall()]
            return is_bookmarked, bookmarks

# Activities

def get_user_activities(username: str, limit: int = 30):
    if not username:
        return []
    with DBConnection() as conn:
        if not conn:
            return []
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, activity_type as type, title, icon,
                       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI') as time
                FROM user_activities
                WHERE username = %s
                ORDER BY created_at DESC LIMIT %s
            """, (username.strip().lower(), limit))
            return [dict(r) for r in cur.fetchall()]

def log_user_activity(username: str, act_type: str, title: str, icon: str = 'fa-bolt'):
    if not username:
        return
    with DBConnection() as conn:
        if not conn:
            return
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO user_activities (username, activity_type, title, icon)
                VALUES (%s, %s, %s, %s)
            """, (username.strip().lower(), act_type, title, icon))
            conn.commit()

# Votes and stats

def get_poll_votes(poll_id: str):
    with DBConnection() as conn:
        if not conn:
            return {'a': 0, 'b': 0, 'total': 0}
        with conn.cursor() as cur:
            cur.execute("""
                SELECT vote, COUNT(*) FROM votes WHERE poll_id = %s GROUP BY vote
            """, (poll_id,))
            scores = {'a': 0, 'b': 0}
            total = 0
            for vote, count in cur.fetchall():
                scores[vote] = count
                total += count
            scores['total'] = total
            return scores

