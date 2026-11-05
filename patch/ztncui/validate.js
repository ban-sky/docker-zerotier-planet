/*
  Small, dependency-free replacement for the subset of express-validator 4
  that ztncui uses. Keeping this shim means the legacy controllers can remain
  unchanged while the vulnerable validator/express-validator packages are
  removed from the image.
*/

const net = require('node:net');

const HTML_ESCAPE = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
  '/': '&#x2F;'
};

class FieldValidator {
  constructor(req, field, message) {
    this.req = req;
    this.field = field;
    this.message = message;
    this.skipped = false;
    this.failed = false;
  }

  get value() {
    return this.req.body ? this.req.body[this.field] : undefined;
  }

  optional(options) {
    if (options && options.checkFalsy && !this.value) this.skipped = true;
    return this;
  }

  fail() {
    if (!this.failed) {
      this.failed = true;
      this.req._validationErrors.push({
        param: this.field,
        msg: this.message,
        value: this.value
      });
    }
    return this;
  }

  notEmpty() {
    if (this.skipped) return this;
    if (typeof this.value !== 'string' || this.value.length === 0) return this.fail();
    return this;
  }

  isLength(options) {
    if (this.skipped) return this;
    const value = this.value;
    if (typeof value !== 'string') return this.fail();
    if (options && options.min !== undefined && value.length < options.min) return this.fail();
    if (options && options.max !== undefined && value.length > options.max) return this.fail();
    return this;
  }

  isIP(family) {
    if (this.skipped) return this;
    const version = net.isIP(String(this.value == null ? '' : this.value));
    if (family === 4 && version !== 4) return this.fail();
    if (family === 6 && version !== 6) return this.fail();
    if (family !== 4 && family !== 6 && version === 0) return this.fail();
    return this;
  }

  isBoolean() {
    if (this.skipped) return this;
    const value = this.value;
    if (value === true || value === false || value === 'true' || value === 'false') {
      return this;
    }
    return this.fail();
  }

  equals(other) {
    if (this.skipped) return this;
    if (this.value !== other) return this.fail();
    return this;
  }

  custom(fn) {
    if (this.skipped) return this;
    let ok = false;
    try {
      ok = fn(this.value) === true;
    } catch (err) {
      ok = false;
    }
    return ok ? this : this.fail();
  }
}

module.exports = function validationShim(req, res, next) {
  req._validationErrors = [];

  req.checkBody = function checkBody(field, message) {
    return new FieldValidator(req, field, message);
  };

  req.sanitize = function sanitize(field) {
    return {
      trim() {
        const value = req.body ? req.body[field] : undefined;
        if (typeof value === 'string') req.body[field] = value.trim();
        return this;
      },
      escape() {
        const value = req.body ? req.body[field] : undefined;
        if (typeof value === 'string') {
          req.body[field] = value.replace(/[&<>"'/]/g, (c) => HTML_ESCAPE[c]);
        }
        return this;
      }
    };
  };

  req.validationErrors = function validationErrors() {
    return req._validationErrors.length ? req._validationErrors : false;
  };

  next();
};
