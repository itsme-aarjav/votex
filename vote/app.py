# pyrefly: ignore [missing-import]
from flask import Flask, render_template, request, make_response, g, jsonify
# pyrefly: ignore [missing-import]
from redis import Redis
import os
import socket
import random
import json
import logging
import time
import hashlib
import uuid

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

# In-memory stores with Redis sync support
USERS_STORE = {}
USER_SESSIONS = {}
USER_ACTIVITIES = {}
USER_BOOKMARKS = {}

def hash_password(password: str, salt: str = None) -> tuple:
    if not salt:
        salt = uuid.uuid4().hex[:16]
    hashed = hashlib.sha256((salt + password).encode('utf-8')).hexdigest()
    return f"{salt}${hashed}"

def verify_password(password: str, stored_hash: str) -> bool:
    try:
        salt, hashed = stored_hash.split('$', 1)
        return hashlib.sha256((salt + password).encode('utf-8')).hexdigest() == hashed
    except Exception:
        return False

# Seed initial default users
def seed_default_users():
    default_users = [
        {
            "id": "u_faza",
            "username": "faza",
            "password_hash": hash_password("faza123"),
            "display_name": "Faza",
            "email": "faza@votex.dev",
            "avatar": "👨🏼‍🚀",
            "bg": "#3b82f6",
            "role": "Pro Pollster",
            "bio": "Lead explorer & UI designer. Always voting for Cats!",
            "level": "Level 4 Explorer",
            "votes_count": 18,
            "polls_count": 3,
            "comments_count": 7,
            "bookmarks": ["cats-dogs", "coffee-tea"],
            "created_at": "2026-01-15"
        },
        {
            "id": "u_momon",
            "username": "momon",
            "password_hash": hash_password("momon123"),
            "display_name": "Momon",
            "email": "momon@votex.dev",
            "avatar": "👩🏻‍💻",
            "bg": "#ec4899",
            "role": "Community Lead",
            "bio": "DevOps engineer passionate about containerized apps and interactive polls.",
            "level": "Level 5 Champion",
            "votes_count": 32,
            "polls_count": 5,
            "comments_count": 14,
            "bookmarks": ["vintage-car"],
            "created_at": "2026-01-10"
        }
    ]
    for u in default_users:
        if u["username"] not in USERS_STORE:
            USERS_STORE[u["username"]] = u
            USER_BOOKMARKS[u["username"]] = set(u.get("bookmarks", []))
            USER_ACTIVITIES[u["username"]] = [
                {"type": "vote", "title": "Voted on Cats vs Dogs", "time": "15 minutes ago", "icon": "fa-check-to-slot"},
                {"type": "comment", "title": "Commented on Cats vs Dogs", "time": "25 minutes ago", "icon": "fa-comment"},
                {"type": "create", "title": "Published Do you like Cats?", "time": "2 hours ago", "icon": "fa-plus-circle"}
            ]

seed_default_users()

# In-memory store for comments
SAMPLE_COMMENTS = [
    {"id": 1, "author": "Nola Sofyan", "avatar": "👩🏻‍🦰", "bg": "#fca5a5", "text": "Cats are definitely more independent and super adorable!", "time": "2 mins ago", "poll_id": "cats-dogs"},
    {"id": 2, "author": "Zhofran", "avatar": "👨🏼‍🦱", "bg": "#86efac", "text": "Vintage cars have unmatched character and timeless soul!", "time": "5 mins ago", "poll_id": "vintage-car"},
    {"id": 3, "author": "Faza", "avatar": "👨🏼‍🚀", "bg": "#3b82f6", "text": "Voted! Great poll design and super smooth animations.", "time": "12 mins ago", "poll_id": "cats-dogs"},
    {"id": 4, "author": "Alex M.", "avatar": "🧔🏻‍♂️", "bg": "#93c5fd", "text": "Can you add a Coffee vs Tea poll next?", "time": "25 mins ago", "poll_id": "coffee-tea"}
]

def get_redis():
    if not hasattr(g, 'redis'):
        try:
            g.redis = Redis(host="redis", db=0, socket_timeout=3)
        except Exception as e:
            app.logger.warning("Redis not available: %s", e)
            g.redis = None
    return g.redis

def get_current_user():
    token = request.cookies.get('auth_token')
    if token and token in USER_SESSIONS:
        username = USER_SESSIONS[token]
        if username in USERS_STORE:
            u = dict(USERS_STORE[username])
            u.pop('password_hash', None)
            u['bookmarks'] = list(USER_BOOKMARKS.get(username, set()))
            return u
    # Default fallback to faza if not explicitly logged out or guest cookie
    if request.cookies.get('guest_mode') == '1':
        return None
    # Auto-login to default demo user faza for seamless first impression
    default_u = dict(USERS_STORE.get("faza", {}))
    default_u.pop('password_hash', None)
    default_u['bookmarks'] = list(USER_BOOKMARKS.get("faza", set()))
    return default_u

def log_activity(username, act_type, title, icon="fa-bolt"):
    if username not in USER_ACTIVITIES:
        USER_ACTIVITIES[username] = []
    USER_ACTIVITIES[username].insert(0, {
        "type": act_type,
        "title": title,
        "time": "Just now",
        "icon": icon,
        "id": int(time.time() * 1000)
    })
    # Keep last 30 activities
    USER_ACTIVITIES[username] = USER_ACTIVITIES[username][:30]

@app.route("/", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    user = get_current_user()
    vote = None

    if request.method == 'POST':
        redis = get_redis()
        if request.is_json:
            data_in = request.get_json(silent=True) or {}
            vote = data_in.get('vote')
        else:
            vote = request.form.get('vote')
            
        if vote and redis:
            app.logger.info('Received vote for %s from %s', vote, voter_id)
            data = json.dumps({'voter_id': voter_id, 'vote': vote})
            try:
                redis.rpush('votes', data)
            except Exception as ex:
                app.logger.error("Redis rpush error: %s", ex)

        if vote and user:
            username = user.get('username')
            if username in USERS_STORE:
                USERS_STORE[username]['votes_count'] = USERS_STORE[username].get('votes_count', 0) + 1
            choice_label = option_a if vote == 'a' else option_b
            log_activity(username, "vote", f"Cast vote for {choice_label}", "fa-check-to-slot")

        if request.is_json or request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            resp = make_response(jsonify({'status': 'ok', 'vote': vote, 'voter_id': voter_id}))
            resp.set_cookie('voter_id', voter_id)
            return resp

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
        voter_id=voter_id,
        initial_comments=SAMPLE_COMMENTS,
        current_user=user
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp

# ----------------- AUTHENTICATION API -----------------

@app.route("/api/auth/register", methods=['POST'])
def api_register():
    data = request.get_json(silent=True) or {}
    username = str(data.get('username', '')).strip().lower()
    password = str(data.get('password', '')).strip()
    display_name = str(data.get('display_name', '')).strip() or username.capitalize()
    email = str(data.get('email', '')).strip()
    avatar = str(data.get('avatar', '👨🏼‍🚀')).strip()
    bg = str(data.get('bg', '#3b82f6')).strip()
    bio = str(data.get('bio', 'Active voter on Votex.')).strip()

    if not username or len(username) < 3:
        return jsonify({"status": "error", "message": "Username must be at least 3 characters"}), 400
    if not password or len(password) < 4:
        return jsonify({"status": "error", "message": "Password must be at least 4 characters"}), 400
    if username in USERS_STORE:
        return jsonify({"status": "error", "message": "Username already exists. Please pick another or sign in."}), 409

    new_user = {
        "id": f"u_{uuid.uuid4().hex[:8]}",
        "username": username,
        "password_hash": hash_password(password),
        "display_name": display_name,
        "email": email or f"{username}@votex.dev",
        "avatar": avatar,
        "bg": bg,
        "role": "Community Voter",
        "bio": bio,
        "level": "Level 1 Explorer",
        "votes_count": 0,
        "polls_count": 0,
        "comments_count": 0,
        "created_at": time.strftime("%Y-%m-%d")
    }
    USERS_STORE[username] = new_user
    USER_BOOKMARKS[username] = set()
    USER_ACTIVITIES[username] = [
        {"type": "system", "title": "Created account and joined Votex", "time": "Just now", "icon": "fa-sparkles"}
    ]

    # Generate session token
    token = uuid.uuid4().hex
    USER_SESSIONS[token] = username

    u_resp = dict(new_user)
    u_resp.pop('password_hash', None)
    u_resp['bookmarks'] = []

    resp = make_response(jsonify({"status": "ok", "message": "Account created successfully!", "user": u_resp}))
    resp.set_cookie('auth_token', token, max_age=86400 * 30, httponly=False)
    resp.set_cookie('guest_mode', '', max_age=0)
    return resp

@app.route("/api/auth/login", methods=['POST'])
def api_login():
    data = request.get_json(silent=True) or {}
    username = str(data.get('username', '')).strip().lower()
    password = str(data.get('password', '')).strip()

    if not username or not password:
        return jsonify({"status": "error", "message": "Username and password required"}), 400

    user = USERS_STORE.get(username)
    if not user or not verify_password(password, user.get('password_hash', '')):
        return jsonify({"status": "error", "message": "Invalid username or password"}), 401

    token = uuid.uuid4().hex
    USER_SESSIONS[token] = username

    u_resp = dict(user)
    u_resp.pop('password_hash', None)
    u_resp['bookmarks'] = list(USER_BOOKMARKS.get(username, set()))

    log_activity(username, "login", "Logged in to Votex", "fa-right-to-bracket")

    resp = make_response(jsonify({"status": "ok", "message": f"Welcome back, {user['display_name']}!", "user": u_resp}))
    resp.set_cookie('auth_token', token, max_age=86400 * 30, httponly=False)
    resp.set_cookie('guest_mode', '', max_age=0)
    return resp

@app.route("/api/auth/logout", methods=['POST'])
def api_logout():
    token = request.cookies.get('auth_token')
    if token and token in USER_SESSIONS:
        del USER_SESSIONS[token]
    resp = make_response(jsonify({"status": "ok", "message": "Logged out successfully"}))
    resp.set_cookie('auth_token', '', max_age=0)
    resp.set_cookie('guest_mode', '1', max_age=86400 * 30)
    return resp

@app.route("/api/auth/me", methods=['GET'])
def api_me():
    user = get_current_user()
    if not user:
        return jsonify({"status": "unauthenticated", "user": None})
    return jsonify({"status": "ok", "user": user})

@app.route("/api/auth/profile", methods=['PUT'])
def api_update_profile():
    user = get_current_user()
    if not user:
        return jsonify({"status": "error", "message": "Authentication required"}), 401
    
    username = user['username']
    data = request.get_json(silent=True) or {}
    
    stored = USERS_STORE.get(username)
    if not stored:
        return jsonify({"status": "error", "message": "User not found"}), 404

    if 'display_name' in data and data['display_name'].strip():
        stored['display_name'] = data['display_name'].strip()
    if 'bio' in data:
        stored['bio'] = data['bio'].strip()
    if 'avatar' in data and data['avatar'].strip():
        stored['avatar'] = data['avatar'].strip()
    if 'bg' in data and data['bg'].strip():
        stored['bg'] = data['bg'].strip()
    if 'role' in data and data['role'].strip():
        stored['role'] = data['role'].strip()

    log_activity(username, "profile_update", "Updated profile settings", "fa-user-pen")

    u_resp = dict(stored)
    u_resp.pop('password_hash', None)
    u_resp['bookmarks'] = list(USER_BOOKMARKS.get(username, set()))

    return jsonify({"status": "ok", "message": "Profile updated successfully!", "user": u_resp})

# ----------------- USER ACTIVITY & BOOKMARKS API -----------------

@app.route("/api/user/activity", methods=['GET'])
def api_user_activity():
    user = get_current_user()
    if not user:
        return jsonify({"activities": []})
    username = user['username']
    return jsonify({"activities": USER_ACTIVITIES.get(username, [])})

@app.route("/api/user/bookmarks", methods=['GET', 'POST'])
def api_user_bookmarks():
    user = get_current_user()
    if not user:
        return jsonify({"status": "error", "message": "Sign in to save bookmarks"}), 401
    
    username = user['username']
    if username not in USER_BOOKMARKS:
        USER_BOOKMARKS[username] = set()

    if request.method == 'POST':
        data = request.get_json(silent=True) or {}
        poll_id = data.get('poll_id')
        if not poll_id:
            return jsonify({"status": "error", "message": "poll_id required"}), 400
        
        is_bookmarked = False
        if poll_id in USER_BOOKMARKS[username]:
            USER_BOOKMARKS[username].remove(poll_id)
            is_bookmarked = False
            log_activity(username, "bookmark", f"Removed bookmark for poll #{poll_id}", "fa-bookmark")
        else:
            USER_BOOKMARKS[username].add(poll_id)
            is_bookmarked = True
            log_activity(username, "bookmark", f"Bookmarked poll #{poll_id}", "fa-bookmark")

        return jsonify({
            "status": "ok",
            "is_bookmarked": is_bookmarked,
            "bookmarks": list(USER_BOOKMARKS[username])
        })

    return jsonify({"bookmarks": list(USER_BOOKMARKS[username])})

# ----------------- COMMENTS API -----------------

@app.route("/api/comments", methods=['GET', 'POST'])
def handle_comments():
    if request.method == 'POST':
        data = request.get_json(silent=True) or {}
        text = data.get('text', '').strip()
        user = get_current_user()
        
        author = user['display_name'] if user else data.get('author', 'Community Member').strip() or 'Community Member'
        avatar = user['avatar'] if user else random.choice(["👩🏻‍🦰", "👨🏼‍🦱", "🧑🏻", "🧔🏻‍♂️", "🧕🏻", "🐱", "🐶"])
        bg = user['bg'] if user else random.choice(["#fca5a5", "#86efac", "#fde047", "#93c5fd", "#d8b4fe"])
        poll_id = data.get('poll_id', 'cats-dogs')

        if text:
            new_comment = {
                "id": int(time.time() * 1000),
                "author": author,
                "avatar": avatar,
                "bg": bg,
                "text": text,
                "time": "Just now",
                "poll_id": poll_id
            }
            SAMPLE_COMMENTS.insert(0, new_comment)
            
            if user:
                username = user['username']
                if username in USERS_STORE:
                    USERS_STORE[username]['comments_count'] = USERS_STORE[username].get('comments_count', 0) + 1
                log_activity(username, "comment", f"Posted comment on poll", "fa-comment")

            return jsonify({"status": "ok", "comment": new_comment})
        return jsonify({"status": "error", "message": "Comment cannot be empty"}), 400
    
    poll_id = request.args.get('poll_id')
    if poll_id:
        filtered = [c for c in SAMPLE_COMMENTS if c.get('poll_id') == poll_id or c.get('poll_id') == 'all']
        return jsonify({"comments": filtered})
    return jsonify({"comments": SAMPLE_COMMENTS})

@app.route("/api/health")
def health():
    redis_status = "connected"
    try:
        r = get_redis()
        if r and r.ping():
            redis_status = "healthy"
        else:
            redis_status = "unhealthy"
    except Exception:
        redis_status = "disconnected"
        
    return jsonify({
        "status": "healthy",
        "service": "vote-python-flask",
        "container_id": hostname,
        "redis": redis_status,
        "timestamp": int(time.time())
    })

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)

