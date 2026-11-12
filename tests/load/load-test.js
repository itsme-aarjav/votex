import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Votex Load & Autoscaling Testing Suite (k6)
// Distinguishes accepted workload, rate-limited traffic (429), and server failures (5xx).
// Validates concurrency, Redis Streams ingestion throughput, and HPA autoscaling.

const TARGET_URL = __ENV.TARGET_URL || 'http://localhost:5002';
const PROFILE = __ENV.PROFILE || 'baseline';

// Custom metric instruments to isolate application performance from security throttling
const successfulVotes = new Counter('successful_votes');
const rateLimitedVotes = new Counter('rate_limited_votes_429');
const clientErrors = new Counter('unexpected_client_errors_4xx');
const serverFailures = new Counter('server_failures_5xx');
const voteLatency = new Trend('vote_submission_duration');
const voteSuccessRate = new Rate('vote_success_rate');

// Configurable load profiles: baseline, stress, spike
const PROFILES = {
  baseline: {
    stages: [
      { duration: '10s', target: 5 },
      { duration: '15s', target: 10 },
      { duration: '5s', target: 0 },
    ],
  },
  stress: {
    stages: [
      { duration: '15s', target: 20 },
      { duration: '30s', target: 50 },
      { duration: '15s', target: 0 },
    ],
  },
  spike: {
    stages: [
      { duration: '10s', target: 20 },
      { duration: '30s', target: 100 },
      { duration: '20s', target: 0 },
    ],
  },
};

const selectedProfile = PROFILES[PROFILE] || PROFILES.baseline;

export const options = {
  stages: selectedProfile.stages,
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    server_failures_5xx: ['count===0'], // Zero 5xx server failures tolerated
  },
};

const POLL_OPTIONS = ['a', 'b'];

export default function () {
  // Model realistic user session: persistent voter identity per Virtual User
  const voterId = `vu-${__VU}`;
  const jar = http.cookieJar();
  jar.set(TARGET_URL, 'voter_id', voterId);

  // 1. Health Probe Check (Readiness / Liveness validation)
  const healthRes = http.get(`${TARGET_URL}/api/health`);
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

  // 2. Fetch Configuration & CSRF Token
  const configRes = http.get(`${TARGET_URL}/api/config`);
  let csrfToken = '';
  check(configRes, {
    'config fetch status is 200': (r) => r.status === 200,
    'config contains csrf_token': (r) => {
      try {
        const json = JSON.parse(r.body);
        if (json.csrf_token) {
          csrfToken = json.csrf_token;
          return true;
        }
        return false;
      } catch (e) {
        return false;
      }
    },
  });

  // 3. Comments Discovery API
  const commentsRes = http.get(`${TARGET_URL}/api/comments`);
  check(commentsRes, {
    'comments fetch status is 200': (r) => r.status === 200,
  });

  // 4. Vote Submission with Valid CSRF Token and Persistent VU Identity
  const randomOption = POLL_OPTIONS[Math.floor(Math.random() * POLL_OPTIONS.length)];
  const votePayload = `vote=${randomOption}&csrf_token=${encodeURIComponent(csrfToken)}&poll_id=cats-dogs`;
  const params = {
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-CSRF-Token': csrfToken,
      'User-Agent': 'k6-load-tester/1.0',
      'Cookie': `voter_id=${voterId}`,
    },
  };

  const voteRes = http.post(`${TARGET_URL}/`, votePayload, params);
  voteLatency.add(voteRes.timings.duration);

  // Categorize responses accurately without masking rate limiting or server crashes
  if (voteRes.status === 200 || voteRes.status === 302) {
    successfulVotes.add(1);
    voteSuccessRate.add(true);
  } else if (voteRes.status === 429) {
    rateLimitedVotes.add(1);
    voteSuccessRate.add(false);
  } else if (voteRes.status >= 400 && voteRes.status < 500) {
    clientErrors.add(1);
    voteSuccessRate.add(false);
  } else if (voteRes.status >= 500) {
    serverFailures.add(1);
    voteSuccessRate.add(false);
  }

  check(voteRes, {
    'vote response received': (r) => r.status !== 0,
    'vote no server 5xx failure': (r) => r.status < 500,
  });

  // Pacing between requests (250ms - 500ms)
  sleep(0.25 + Math.random() * 0.25);
}
