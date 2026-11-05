/*
  ztncui - ZeroTier network controller UI
  Copyright (C) 2017-2021  Key Networks (https://key-networks.com)
  Licensed under GPLv3 - see LICENSE for details.

  Hardened entry point for the container image.
*/

const crypto = require('crypto');
const express = require('express');
const path = require('path');
const favicon = require('serve-favicon');
const logger = require('morgan');
const cookieParser = require('cookie-parser');
const bodyParser = require('body-parser');
const expressValidator = require('express-validator');
const session = require('express-session');
const helmet = require('helmet');

const index = require('./routes/index');
const users = require('./routes/users');
const zt_controller = require('./routes/zt_controller');

const app = express();
app.disable('x-powered-by');

const isProduction = process.env.NODE_ENV === 'production';
const tlsEnabled = process.env.TLS_ENABLED === '1';

// A stable secret is required so sessions survive a restart. Generate one in
// the entrypoint; the random fallback is only for local development.
let sessionSecret = process.env.SESSION_SECRET;
if (!sessionSecret || sessionSecret.length < 32) {
  if (isProduction) {
    console.error('FATAL: SESSION_SECRET must be set to at least 32 characters');
    process.exit(1);
  }
  sessionSecret = crypto.randomBytes(32).toString('hex');
}

if (process.env.TRUST_PROXY) {
  const v = process.env.TRUST_PROXY;
  app.set('trust proxy', /^\d+$/.test(v) ? parseInt(v, 10) : v);
}

/*
 * Minimal in-memory session store. It has the same persistence properties as
 * express-session's MemoryStore but does not emit the "not designed for
 * production" warning (#185). Sessions are intentionally invalidated on
 * restart; the UI is a single-admin control panel, not a multi-tenant app.
 */
class BoundedMemoryStore extends session.Store {
  constructor(options) {
    super();
    this.ttlMs = (options && options.ttlMs) || 8 * 60 * 60 * 1000;
    this.sessions = new Map();
    this.timer = setInterval(() => this.prune(), 15 * 60 * 1000);
    if (this.timer.unref) this.timer.unref();
  }

  prune() {
    const now = Date.now();
    for (const [sid, entry] of this.sessions) {
      if (entry.expires <= now) this.sessions.delete(sid);
    }
  }

  get(sid, cb) {
    const entry = this.sessions.get(sid);
    if (!entry || entry.expires <= Date.now()) {
      if (entry) this.sessions.delete(sid);
      return cb(null, null);
    }
    return cb(null, entry.session);
  }

  set(sid, sess, cb) {
    const expires = sess && sess.cookie && sess.cookie.expires
      ? new Date(sess.cookie.expires).getTime()
      : Date.now() + this.ttlMs;
    this.sessions.set(sid, { session: sess, expires });
    if (cb) cb(null);
  }

  destroy(sid, cb) {
    this.sessions.delete(sid);
    if (cb) cb(null);
  }

  touch(sid, sess, cb) {
    const entry = this.sessions.get(sid);
    if (entry) {
      entry.expires = sess && sess.cookie && sess.cookie.expires
        ? new Date(sess.cookie.expires).getTime()
        : Date.now() + this.ttlMs;
    }
    if (cb) cb(null);
  }
}

// view engine setup
app.set('views', path.join(__dirname, 'views'));
app.set('view engine', 'pug');

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      // ztncui ships small inline jQuery snippets in its Pug views.
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:'],
      fontSrc: ["'self'"],
      connectSrc: ["'self'"],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"]
    }
  },
  hsts: tlsEnabled ? { maxAge: 15552000, includeSubDomains: false } : false,
  referrerPolicy: { policy: 'no-referrer' }
}));
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');
  next();
});
app.use(favicon(path.join(__dirname, 'public', 'favicon.ico')));
app.use(logger(isProduction ? 'combined' : 'dev'));

/*
 * CSRF defence in depth: every state-changing request must originate from the
 * same host when the browser sends Origin/Referer. Session cookies are also
 * SameSite=Lax, so a cross-site form POST will not carry them.
 */
app.use((req, res, next) => {
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return next();
  const source = req.get('origin') || req.get('referer');
  if (!source) return next(); // non-browser client; still needs a session cookie
  let sourceHost;
  try {
    sourceHost = new URL(source).host;
  } catch (err) {
    return res.status(403).type('text/plain').send('Bad request origin');
  }
  if (sourceHost !== req.get('host')) {
    return res.status(403).type('text/plain').send('Bad request origin');
  }
  next();
});

app.use(bodyParser.json({ limit: '256kb' }));
app.use(bodyParser.urlencoded({ extended: false, limit: '256kb' }));
app.use(cookieParser());
app.use(session({
  name: 'ztncui.sid',
  resave: false,
  saveUninitialized: false,
  rolling: true,
  secret: sessionSecret,
  store: new BoundedMemoryStore({ ttlMs: 8 * 60 * 60 * 1000 }),
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    secure: tlsEnabled,
    maxAge: 8 * 60 * 60 * 1000
  }
}));
app.use(expressValidator());
app.use(express.static(path.join(__dirname, 'public')));
app.use('/fonts', express.static(path.join(__dirname, 'node_modules/bootstrap/fonts')));
app.use('/bscss', express.static(path.join(__dirname, 'node_modules/bootstrap/dist/css')));
app.use('/jqjs', express.static(path.join(__dirname, 'node_modules/jquery/dist')));
app.use('/bsjs', express.static(path.join(__dirname, 'node_modules/bootstrap/dist/js')));

app.use('/', index);
app.use('/users', users);
app.use('/controller', zt_controller);

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  })[c]);
}

// flash messages
app.use(function(req, res, next) {
  const err = req.session && req.session.error;
  const msg = req.session && req.session.success;
  if (req.session) {
    delete req.session.error;
    delete req.session.success;
  }
  res.locals.message = '';
  if (err) res.locals.message = '<p class="msg error">' + escapeHtml(err) + '</p>';
  if (msg) res.locals.message = '<p class="msg success">' + escapeHtml(msg) + '</p>';
  next();
});

// catch 404
app.use(function(req, res) {
  res.status(404).render('error', {
    message: 'Not found',
    error: isProduction ? {} : { status: 404, stack: '' }
  });
});

// error handler: never leak stack traces or filesystem paths to clients
app.use(function(err, req, res, next) {
  if (res.headersSent) return next(err);
  const status = err.status || 500;
  if (status >= 500) console.error(err && err.stack ? err.stack : err);
  res.status(status);
  res.render('error', {
    message: status >= 500 ? 'Internal server error' : 'Request error',
    error: isProduction ? {} : { status, stack: err.stack || '' }
  });
});

module.exports = app;
