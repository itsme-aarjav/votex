-- Votex PostgreSQL Schema Initialization

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

-- Seed default initial polls if not present
INSERT INTO polls (id, title, greeting, creator, image, option_a, option_b)
VALUES
    ('cats-dogs', 'Do you like this Cat? (Cats vs Dogs)', 'Hi Faza!', 'Momon', '/static/images/cat.jpg', 'Cats', 'Dogs'),
    ('vintage-car', 'Do you like this Classic Beetle Car?', 'Hi Guys!', 'Aarjav', '/static/images/car.jpg', 'Yes!', 'No!'),
    ('coffee-tea', 'Morning Fuel: Coffee or Tea?', 'Good Morning!', 'Nola', 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd?w=800&q=80', 'Coffee ☕', 'Tea 🍵')
ON CONFLICT (id) DO NOTHING;

-- Seed default comments
INSERT INTO comments (poll_id, author, avatar, bg, text)
SELECT 'cats-dogs', 'Nola Sofyan', '👩🏻‍🦰', '#fca5a5', 'Cats are definitely more independent and super adorable!'
WHERE NOT EXISTS (SELECT 1 FROM comments WHERE poll_id = 'cats-dogs' AND author = 'Nola Sofyan');

INSERT INTO comments (poll_id, author, avatar, bg, text)
SELECT 'vintage-car', 'Zhofran', '👨🏼‍🦱', '#86efac', 'Vintage cars have unmatched character and timeless soul!'
WHERE NOT EXISTS (SELECT 1 FROM comments WHERE poll_id = 'vintage-car' AND author = 'Zhofran');

