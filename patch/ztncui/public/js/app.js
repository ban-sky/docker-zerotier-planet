/* ztncui modern UI - progressive enhancement only. */
(function () {
  'use strict';

  var toggle = document.querySelector('[data-nav-toggle]');
  var nav = document.getElementById('primary-nav');
  if (toggle && nav) {
    toggle.addEventListener('click', function () {
      var open = nav.classList.toggle('is-open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
  }

  document.querySelectorAll('[data-confirm]').forEach(function (el) {
    el.addEventListener('click', function (event) {
      if (!window.confirm(el.getAttribute('data-confirm'))) event.preventDefault();
    });
  });

  document.querySelectorAll('[data-autosubmit]').forEach(function (el) {
    el.addEventListener('change', function () {
      if (el.form) el.form.requestSubmit();
    });
  });

  document.querySelectorAll('[data-copy]').forEach(function (button) {
    button.addEventListener('click', function () {
      var text = button.getAttribute('data-copy');
      if (navigator.clipboard && text) navigator.clipboard.writeText(text);
    });
  });

  var form = document.getElementById('easy-form');
  if (form) {
    var cidr = document.getElementById('networkCIDR');
    var start = document.getElementById('poolStart');
    var end = document.getElementById('poolEnd');

    function ipv4ToInt(address) {
      var parts = address.split('.');
      if (parts.length !== 4) return null;
      var value = 0;
      for (var i = 0; i < 4; i += 1) {
        var octet = Number(parts[i]);
        if (!Number.isInteger(octet) || octet < 0 || octet > 255) return null;
        value = (value * 256) + octet;
      }
      return value >>> 0;
    }

    function intToIpv4(value) {
      value = value >>> 0;
      return [value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255].join('.');
    }

    function fillPool() {
      var value = cidr.value.trim();
      var pieces = value.split('/');
      if (pieces.length !== 2 || !/^\d{1,2}$/.test(pieces[1])) return;
      var prefix = Number(pieces[1]);
      var network = ipv4ToInt(pieces[0]);
      if (network === null || prefix < 8 || prefix > 30) return;
      var size = Math.pow(2, 32 - prefix) >>> 0;
      var mask = size - 1;
      var base = (network & ~mask) >>> 0;
      start.value = intToIpv4(base + 1);
      end.value = intToIpv4(base + size - 2);
      cidr.value = intToIpv4(base) + '/' + prefix;
    }

    function randomCidr() {
      var a = 16 + Math.floor(Math.random() * 16);
      var b = Math.floor(Math.random() * 256);
      cidr.value = '10.' + a + '.' + b + '.0/24';
      fillPool();
    }

    cidr.addEventListener('change', fillPool);
    cidr.addEventListener('blur', fillPool);
    var randomButton = document.querySelector('[data-random-cidr]');
    if (randomButton) randomButton.addEventListener('click', randomCidr);
  }
})();
