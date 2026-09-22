import pytest
import sys
import os

# Add parent directory to import path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'vote')))

from app import app, hash_password, verify_password

@pytest.fixture
def client():
    app.config['TESTING'] = True
    with app.test_client() as client:
        yield client

def test_home_page(client):
    """Test that the homepage renders successfully"""
    res = client.get('/')
    assert res.status_code == 200
    assert b"Votex" in res.data

def test_health_endpoint(client):
    """Test the /api/health endpoint for Kubernetes liveness/readiness probes"""
    res = client.get('/api/health')
    assert res.status_code == 200
    data = res.get_json()
    assert data['status'] == 'healthy'
    assert 'service' in data
    assert 'container_id' in data

def test_password_hashing():
    """Test secure password hashing and verification"""
    raw_pass = "SecurePass123!"
    hashed = hash_password(raw_pass)
    assert hashed != raw_pass
    assert verify_password(raw_pass, hashed) is True
    assert verify_password("WrongPass", hashed) is False

def test_comments_api(client):
    """Test /api/comments endpoint returns comment list"""
    res = client.get('/api/comments')
    assert res.status_code == 200
    data = res.get_json()
    assert 'comments' in data
    assert len(data['comments']) > 0

def test_auth_login_validation(client):
    """Test login validation with invalid credentials"""
    res = client.post('/api/auth/login', json={
        "username": "nonexistent_user",
        "password": "wrongpassword"
    })
    assert res.status_code == 401
