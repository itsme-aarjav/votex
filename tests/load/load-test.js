import http from 'k6/http';
import { check, sleep } from 'k6';

// -------------------------------------------------------------
// Votex High-Concurrency Load & Stress Test Suite (k6)
// Designed to stress the Vote service and trigger Kubernetes HPA
// -------------------------------------------------------------

export const options = {
  stages: [
    { duration: '30s', target: 50 },  // Warm-up / baseline load
    { duration: '1m',  target: 150 }, // Ramp-up: stress queue & memory
    { duration: '1m',  target: 300 }, // Peak spike: trigger HorizontalPodAutoscaler (CPU > 60%)
    { duration: '30s', target: 50 },  // Cool-down / HPA scale-in verification
    { duration: '10s', target: 0 },   // Complete
  ],
  thresholds: {
    // 95% of requests must complete below 500ms
    http_req_duration: ['p(95)<500'],
    // Error rate must stay below 2%
    http_req_failed: ['rate<0.02'],
  },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:5002';

const POLL_OPTIONS = ['a', 'b', 'c', 'd'];

export default function () {
  // 1. Health Probe Check (Readiness / Liveness validation)
  const healthRes = http.get(`${BASE_URL}/api/health`);
  check(healthRes, {
    'health check status is 200': (r) => r.status === 200,
    'health returns healthy status': (r) => {
      try {
        return JSON.parse(r.body).status === 'healthy';
      } catch (e) {
        return false;
      }
    },
  });

  // 2. Comments Discovery API
  const commentsRes = http.get(`${BASE_URL}/api/comments`);
  check(commentsRes, {
    'comments fetch status is 200': (r) => r.status === 200,
  });

  // 3. High-throughput Vote Casting (Stresses Redis in-memory queue & worker)
  const randomOption = POLL_OPTIONS[Math.floor(Math.random() * POLL_OPTIONS.length)];
  const votePayload = `vote=${randomOption}`;
  const params = {
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'k6-load-tester/1.0',
    },
  };

  const voteRes = http.post(BASE_URL, votePayload, params);
  check(voteRes, {
    'vote submission succeeds (200 or 302)': (r) => r.status === 200 || r.status === 302,
  });

  // Random pacing between requests (100ms - 300ms)
  sleep(0.1 + Math.random() * 0.2);
}
