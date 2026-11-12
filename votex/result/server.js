var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    path = require('path'),
    cookieParser = require('cookie-parser'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server);

var otelEnabled = (process.env.OTEL_ENABLED || 'true').toLowerCase() === 'true';
var tracer = null;
var otelContext = null;
var otelPropagation = null;
var tracerProvider = null;
if (otelEnabled) {
  try {
    var otelApi = require('@opentelemetry/api');
    try {
      var { BasicTracerProvider, BatchSpanProcessor } = require('@opentelemetry/sdk-trace-base');
      var { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
      var { Resource } = require('@opentelemetry/resources');

      var resource = new Resource({
        'service.name': 'votex-result',
        'service.version': '2.1.0'
      });
      tracerProvider = new BasicTracerProvider({ resource: resource });
      var endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://otel-collector:4318/v1/traces';
      var exporter = new OTLPTraceExporter({ url: endpoint });
      tracerProvider.addSpanProcessor(new BatchSpanProcessor(exporter));
      tracerProvider.register();
    } catch (_sdkErr) {
      // SDK not installed or core API fallback
    }
    tracer = otelApi.trace.getTracer('votex-result', '2.1.0');
    otelContext = otelApi.context;
    otelPropagation = otelApi.propagation;
  } catch (err) {
    tracer = null;
    otelContext = null;
    otelPropagation = null;
  }
}

var metricRequestsTotal = 0;
var metricErrorsTotal = 0;
var metricDbQueriesTotal = 0;
var metricSocketConnections = 0;

app.use(function (req, res, next) {
  if (req.path !== '/metrics') {
    metricRequestsTotal++;
    res.on('finish', function () {
      if (res.statusCode >= 400) {
        metricErrorsTotal++;
      }
    });
  }
  if (tracer) {
    var parentCtx = (otelPropagation && otelContext)
      ? otelPropagation.extract(otelContext.active(), req.headers)
      : undefined;
    var span = tracer.startSpan('http_request_' + req.method.toLowerCase(), {}, parentCtx);
    span.setAttribute('http.method', req.method);
    span.setAttribute('http.target', req.url);
    res.on('finish', function () {
      span.setAttribute('http.status_code', res.statusCode);
      span.end();
    });
  }
  next();
});

var port = process.env.PORT || 80;
var voteUrl = process.env.VOTE_URL || '/';

var pgHost = process.env.POSTGRES_HOST || 'db';
var pgPort = process.env.POSTGRES_PORT || 5432;
var pgUser = process.env.POSTGRES_USER || 'postgres';
var pgPass = process.env.POSTGRES_PASSWORD || '';
var pgDb = process.env.POSTGRES_DB || 'postgres';
var dbUrl = process.env.DATABASE_URL;

var pool = new Pool(dbUrl ? { connectionString: dbUrl } : {
  host: pgHost,
  port: parseInt(pgPort, 10),
  user: pgUser,
  password: pgPass,
  database: pgDb,
  connectionTimeoutMillis: 5000
});

var origPoolQuery = pool.query.bind(pool);
pool.query = function (...args) {
  metricDbQueriesTotal++;
  return origPoolQuery(...args);
};

io.on('connection', function (socket) {
  metricSocketConnections++;
  socket.emit('message', { text: 'Welcome!' });

  socket.on('disconnect', function () {
    metricSocketConnections = Math.max(0, metricSocketConnections - 1);
  });

  socket.on('subscribe', function (data) {
    if (data && data.channel) {
      socket.join(data.channel);
    }
  });
});

if (require.main === module) {
  async.retry(
    { times: 1000, interval: 1000 },
    function (callback) {
      pool.connect(function (err, client, done) {
        if (err) {
          console.error("Waiting for PostgreSQL database...");
        }
        callback(err, client, done);
      });
    },
    function (err, client, done) {
      if (err) {
        return console.error("Giving up database connection");
      }
      console.log("Connected to PostgreSQL database successfully");
      if (done) done();
      pollDatabaseMetrics();
    }
  );
}

function pollDatabaseMetrics() {
  getVotesAndAnalytics(function () {
    setTimeout(pollDatabaseMetrics, 1000);
  });
}

function getVotesAndAnalytics(callback) {
  // Query per-poll vote breakdown
  pool.query('SELECT poll_id, vote, COUNT(id) AS count FROM votes GROUP BY poll_id, vote', [], function (err, votesResult) {
    if (err) {
      console.error("Error performing votes query: " + err);
      return callback();
    }

    // Query overall totals and unique voters
    pool.query('SELECT COUNT(DISTINCT id) AS unique_voters, COUNT(*) AS total_votes FROM votes', [], function (totalErr, totalResult) {
      if (totalErr) {
        console.error("Error performing totals query: " + totalErr);
        return callback();
      }

      // Query recent votes with voter info
      pool.query(`
        SELECT v.id, v.poll_id, v.vote, v.updated_at,
               COALESCE(u.display_name, 'Voter ' || SUBSTRING(v.id, 1, 6)) AS name,
               COALESCE(u.avatar, '🗳️') AS avatar,
               COALESCE(u.bg, '#3b82f6') AS bg
        FROM votes v
        LEFT JOIN users u ON u.id = v.id OR u.username = v.id
        ORDER BY v.updated_at DESC
        LIMIT 8
      `, [], function (recErr, recentResult) {
        var analyticsData = buildAnalyticsPayload(votesResult, totalResult, recErr ? null : recentResult);
        io.sockets.emit("scores", JSON.stringify(analyticsData));
        callback();
      });
    });
  });
}

function buildAnalyticsPayload(votesResult, totalResult, recentResult) {
  var polls = {};
  var globalA = 0;
  var globalB = 0;

  votesResult.rows.forEach(function (row) {
    var pId = row.poll_id || 'cats-dogs';
    if (!polls[pId]) {
      polls[pId] = { a: 0, b: 0, total: 0 };
    }
    var cnt = parseInt(row.count, 10) || 0;
    if (row.vote === 'a') {
      polls[pId].a += cnt;
      globalA += cnt;
    } else if (row.vote === 'b') {
      polls[pId].b += cnt;
      globalB += cnt;
    }
    polls[pId].total += cnt;
  });

  var totalVotes = 0;
  var uniqueVoters = 0;
  if (totalResult && totalResult.rows.length > 0) {
    totalVotes = parseInt(totalResult.rows[0].total_votes, 10) || 0;
    uniqueVoters = parseInt(totalResult.rows[0].unique_voters, 10) || 0;
  }

  var recentVotes = [];
  if (recentResult && recentResult.rows.length > 0) {
    recentVotes = recentResult.rows.map(function (row) {
      return {
        name: row.name,
        choice: row.vote === 'a' ? 'Option A' : 'Option B',
        type: row.vote,
        avatar: row.avatar,
        bg: row.bg,
        poll_id: row.poll_id
      };
    });
  }

  return {
    // Top-level legacy keys for backward compatibility
    a: globalA,
    b: globalB,
    total: totalVotes,
    uniqueVoters: uniqueVoters,
    polls: polls,
    recentVotes: recentVotes
  };
}

app.use(cookieParser());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(__dirname + '/views'));

// Health check endpoint for Kubernetes liveness/readiness probes
app.get('/api/health', async function (req, res) {
  try {
    await pool.query('SELECT 1');
    res.json({
      status: 'healthy',
      service: 'votex-result-node',
      port: port,
      timestamp: Date.now()
    });
  } catch (err) {
    res.status(503).json({
      status: 'unhealthy',
      service: 'votex-result-node',
      error: err.message
    });
  }
});

// Real CSV export containing actual PostgreSQL voting data
app.get(['/api/export-csv', '/export.csv'], async function (req, res) {
  try {
    var result = await pool.query(`
      SELECT p.id as poll_id, p.title as poll_title, p.option_a, p.option_b,
             COALESCE(SUM(CASE WHEN v.vote = 'a' THEN 1 ELSE 0 END), 0) as count_a,
             COALESCE(SUM(CASE WHEN v.vote = 'b' THEN 1 ELSE 0 END), 0) as count_b,
             COUNT(v.id) as total_votes
      FROM polls p
      LEFT JOIN votes v ON v.poll_id = p.id
      GROUP BY p.id, p.title, p.option_a, p.option_b
      ORDER BY p.id
    `);

    var csv = 'Poll ID,Poll Title,Option A,Option A Votes,Option B,Option B Votes,Total Votes\n';
    result.rows.forEach(function (r) {
      var titleSafe = '"' + (r.poll_title || '').replace(/"/g, '""') + '"';
      var optASafe = '"' + (r.option_a || 'A').replace(/"/g, '""') + '"';
      var optBSafe = '"' + (r.option_b || 'B').replace(/"/g, '""') + '"';
      csv += r.poll_id + ',' + titleSafe + ',' + optASafe + ',' + r.count_a + ',' + optBSafe + ',' + r.count_b + ',' + r.total_votes + '\n';
    });

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="votex_analytics.csv"');
    res.send(csv);
  } catch (err) {
    console.error('CSV export query error:', err);
    res.status(500).send('Error generating CSV export');
  }
});

// Config endpoint providing frontend URLs dynamically
app.get('/api/config', function (req, res) {
  res.json({
    vote_url: voteUrl,
    port: port
  });
});

app.get('/metrics', function (req, res) {
  var metrics = [
    '# HELP votex_result_http_requests_total Total HTTP requests received by Result service',
    '# TYPE votex_result_http_requests_total counter',
    'votex_result_http_requests_total ' + metricRequestsTotal,
    '# HELP votex_result_http_errors_total Total HTTP error responses (4xx/5xx)',
    '# TYPE votex_result_http_errors_total counter',
    'votex_result_http_errors_total ' + metricErrorsTotal,
    '# HELP votex_result_db_queries_total Total PostgreSQL queries executed',
    '# TYPE votex_result_db_queries_total counter',
    'votex_result_db_queries_total ' + metricDbQueriesTotal,
    '# HELP votex_result_ws_connections_current Current connected WebSocket clients',
    '# TYPE votex_result_ws_connections_current gauge',
    'votex_result_ws_connections_current ' + metricSocketConnections,
    '# HELP votex_service_info Information about the Votex Result service',
    '# TYPE votex_service_info gauge',
    'votex_service_info{service="result",version="2.1.0"} 1',
    ''
  ].join('\n');
  res.set('Content-Type', 'text/plain; version=0.0.4; charset=utf-8');
  res.send(metrics);
});

app.get('/', function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

if (require.main === module) {
  server.listen(port, function () {
    console.log('App running on port ' + port);
  });
}

module.exports = { app, server, pool, buildAnalyticsPayload };
