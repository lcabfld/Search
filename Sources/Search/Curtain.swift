import Foundation
import WebKit

// Taking things off a page and keeping them off.
//
// Point at a cookie bar, a newsletter overlay, a sidebar of related nonsense —
// it goes, and it is still gone next time. Everything is remembered by site, as
// a list of selectors, and put back on by a stylesheet injected before the page
// has drawn a single frame, so nothing is ever seen appearing and vanishing.

struct Veil: Codable, Identifiable, Equatable {
    var selector: String
    /// What it was, in words, so the list of what you have hidden reads like
    /// something rather than like a stylesheet.
    var label: String
    /// How big it was and where it sat — measured when you hid it, because a
    /// hidden thing has no size to measure later. Two elements can easily read
    /// the same; they rarely have the same shape in the same corner.
    var note: String?
    var date: Date

    var id: String { selector }
}

@MainActor
final class Curtain: ObservableObject {
    @Published private(set) var byHost: [String: [Veil]] = [:]
    private var saving = false

    init() { load() }

    func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func veils(on host: String?) -> [Veil] {
        guard let host else { return [] }
        return byHost[host] ?? []
    }

    func hide(_ selector: String, label: String, note: String, on host: String) {
        var list = byHost[host] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return }
        list.append(Veil(selector: selector, label: label, note: note, date: Date()))
        byHost[host] = list
        save()
    }

    /// Put one back.
    func restore(_ veil: Veil, on host: String) {
        byHost[host] = (byHost[host] ?? []).filter { $0.selector != veil.selector }
        if byHost[host]?.isEmpty == true { byHost[host] = nil }
        save()
    }

    /// Put the last one back — ⌘Z, while you are still pointing at things.
    @discardableResult
    func undo(on host: String) -> Veil? {
        guard var list = byHost[host], let last = list.popLast() else { return nil }
        byHost[host] = list.isEmpty ? nil : list
        save()
        return last
    }

    func restoreAll(on host: String) {
        byHost[host] = nil
        save()
    }

    /// The stylesheet for a site. Each selector stands alone in its own rule:
    /// one selector the browser can't parse would otherwise take the whole
    /// list down with it.
    /// One selector may be left out — that is how a row in the list shows you
    /// what it is offering to bring back, without bringing it back.
    func css(on host: String?, without spared: String? = nil) -> String {
        veils(on: host)
            .filter { $0.selector != spared }
            .map { "\($0.selector) { display: none !important; }" }
            .joined(separator: "\n")
    }

    // MARK: - the file

    private static var file: URL { Store.file("hidden.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Curtain.file),
              let stored = try? JSONDecoder().decode([String: [Veil]].self, from: data)
        else { return }
        byHost = stored
    }

    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            saving = false
            let snapshot = byHost
            let file = Curtain.file
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

/// Carries a chosen element back from the page.
final class VeilRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeVeil"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if let trouble = body["trouble"] as? String {
                tab?.pickingFailed(trouble)
            } else if body["off"] as? Bool == true {
                tab?.pickingEnded()
            } else if let selector = body["selector"] as? String {
                tab?.picked(
                    selector: selector,
                    label: body["label"] as? String ?? selector,
                    note: body["note"] as? String ?? ""
                )
            }
        }
    }
}

enum Veiling {
    /// A stylesheet put in before the document has a body, so nothing is ever
    /// seen arriving and then leaving.
    static func style(_ css: String) -> String {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        (function () {
          var sheet = document.getElementById('office-veil');
          if (!sheet) {
            sheet = document.createElement('style');
            sheet.id = 'office-veil';
            (document.head || document.documentElement).appendChild(sheet);
          }
          sheet.textContent = `\(escaped)`;
        })();
        """
    }

    /// The pointing mode. Loaded on every page but asleep: it costs one closure
    /// and a few functions until somebody actually asks for it.
    static let picker = """
    (function () {
      if (window.__officeVeil) return;
      var frame = null, tag = null, edge = null, target = null, live = false;
      // The elements ↑ walked out of, for ↓ to walk back into.
      var trail = [];
      var PINK = '255,55,95';
      // The family, not the one: every element like the one pointed at.
      // Search says which (mode); ⌥ held turns it round for as long as it is.
      var all = false, flipped = false;
      // The family's other boxes, drawn from a pool so a page of a hundred
      // headlines isn't a hundred new elements on every move.
      var pool = [];

      function sheet(id) {
        var s = document.getElementById(id);
        if (!s) {
          s = document.createElement('style');
          s.id = id;
          (document.head || document.documentElement).appendChild(s);
        }
        return s;
      }

      // A bolt for the pointer, as Arc's Zap has: drawn here, so no file.
      var bolt = 'data:image/svg+xml,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">' +
        '<path d="M13.5 1.5 4 13.5h6.5L9 22.5l10-12.5h-6.6z" fill="rgb(' + PINK + ')" ' +
        'stroke="white" stroke-width="1.6" stroke-linejoin="round"/></svg>');

      function chrome() {
        if (frame) return frame;
        frame = document.createElement('div');
        frame.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;' +
          'box-sizing:border-box;border:2px solid rgba(' + PINK + ',.95);' +
          'background:rgba(' + PINK + ',.13);' +
          'box-shadow:0 0 0 4px rgba(' + PINK + ',.16),0 6px 24px rgba(' + PINK + ',.18);' +
          'border-radius:6px;opacity:0;' +
          'transition:left .14s cubic-bezier(.2,.8,.2,1),top .14s cubic-bezier(.2,.8,.2,1),' +
          'width .14s cubic-bezier(.2,.8,.2,1),height .14s cubic-bezier(.2,.8,.2,1),' +
          'border-radius .14s,opacity .12s';
        tag = document.createElement('div');
        tag.style.cssText = 'position:absolute;display:flex;align-items:center;gap:6px;' +
          'font:600 11px -apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.01em;' +
          'color:#fff;background:rgb(' + PINK + ');padding:3px 8px 3px 7px;' +
          'border-radius:7px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' +
          'box-shadow:0 2px 8px rgba(0,0,0,.18)';
        frame.appendChild(tag);
        // The whole page, edged in the same pink while Zap is on.
        edge = document.createElement('div');
        edge.style.cssText = 'position:fixed;inset:0;z-index:2147483645;pointer-events:none;' +
          'box-shadow:inset 0 0 0 3px rgba(' + PINK + ',.85),inset 0 0 40px rgba(' + PINK + ',.12);' +
          'opacity:0;transition:opacity .2s';
        document.documentElement.appendChild(edge);
        document.documentElement.appendChild(frame);
        return frame;
      }

      function hideBox() {
        if (frame) frame.style.opacity = '0';
        for (var i = 0; i < pool.length; i++) pool[i].style.display = 'none';
      }

      function wantsAll() { return all !== flipped; }

      function poolBox(i) {
        if (pool[i]) return pool[i];
        var b = document.createElement('div');
        b.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;box-sizing:border-box;' +
          'border:1.5px solid rgba(' + PINK + ',.75);background:rgba(' + PINK + ',.09);' +
          'border-radius:5px;display:none';
        document.documentElement.appendChild(b);
        pool[i] = b;
        return b;
      }

      function matches(sel) {
        try { return document.querySelectorAll(sel); } catch (e) { return []; }
      }

      function steadyClasses(el) {
        return (el.className && typeof el.className === 'string')
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
      }

      // A selector for every element like this one: the narrowest that
      // still finds more than one, tried from the most telling — all its
      // classes, a test hook, one class, then its tag inside the nearest
      // ancestor with a name. Never a bare tag, which would be the page.
      function family(el) {
        var tagName = el.tagName.toLowerCase();
        var classes = steadyClasses(el);
        var tries = [];
        if (classes.length > 1) tries.push(tagName + '.' + classes.map(CSS.escape).join('.'));
        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'data-component', 'data-type', 'itemprop'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) tries.push(tagName + '[' + hooks[i] + '="' + CSS.escape(v) + '"]');
        }
        var singles = classes.map(function (c) { return tagName + '.' + CSS.escape(c); })
          .map(function (sel) { return { sel: sel, n: matches(sel).length }; })
          .filter(function (t) { return t.n >= 2; })
          .sort(function (a, b) { return a.n - b.n; });
        singles.forEach(function (t) { tries.push(t.sel); });
        var node = el.parentElement, depth = 0;
        while (node && node !== document.body && node !== document.documentElement && depth < 6) {
          var anchor = null;
          if (node.id && unique('#' + CSS.escape(node.id))) anchor = '#' + CSS.escape(node.id);
          else {
            var ac = steadyClasses(node);
            if (ac.length) anchor = node.tagName.toLowerCase() + '.' + CSS.escape(ac[0]);
          }
          if (anchor) {
            tries.push(anchor + ' ' + tagName + (classes.length ? '.' + CSS.escape(classes[0]) : ''));
            tries.push(anchor + ' ' + tagName);
            break;
          }
          node = node.parentElement;
          depth++;
        }
        for (var k = 0; k < tries.length; k++) {
          var found = matches(tries[k]);
          if (found.length >= 2 && found.length <= 400 &&
              Array.prototype.indexOf.call(found, el) !== -1) {
            return { selector: tries[k], nodes: found };
          }
        }
        return null;
      }

      function place(el) {
        var box = chrome(), r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return hideBox();
        var radius = 6;
        try { radius = Math.max(4, parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0); } catch (e) {}
        box.style.opacity = '1';
        box.style.left = (r.left - 2) + 'px';
        box.style.top = (r.top - 2) + 'px';
        box.style.width = (r.width + 4) + 'px';
        box.style.height = (r.height + 4) + 'px';
        box.style.borderRadius = Math.min(radius + 2, 24) + 'px';
        var size = Math.round(r.width) + ' × ' + Math.round(r.height);
        tag.innerHTML = '';
        var label = document.createElement('span');
        label.textContent = name(el);
        var dims = document.createElement('span');
        dims.textContent = size;
        dims.style.cssText = 'font-weight:500;opacity:.75';
        tag.appendChild(label);
        tag.appendChild(dims);
        for (var i = 0; i < pool.length; i++) pool[i].style.display = 'none';
        if (wantsAll()) {
          var fam = family(el);
          if (fam) {
            dims.textContent = fam.nodes.length + ' like this';
            var drawn = 0;
            for (var j = 0; j < fam.nodes.length && drawn < 200; j++) {
              var other = fam.nodes[j];
              if (other === el) continue;
              var o = other.getBoundingClientRect();
              if (o.width < 1 || o.height < 1 || o.bottom < 0 || o.top > window.innerHeight) continue;
              var b = poolBox(drawn++);
              b.style.display = 'block';
              b.style.left = (o.left - 2) + 'px';
              b.style.top = (o.top - 2) + 'px';
              b.style.width = (o.width + 4) + 'px';
              b.style.height = (o.height + 4) + 'px';
            }
          } else {
            dims.textContent = 'only one like this';
          }
        }
        // Above the element if there is sky above it, tucked inside its top
        // edge if there isn't — an element flush with the top of the window
        // would otherwise have its name cut off by the window.
        tag.style.top = r.top >= 28 ? '-25px' : '4px';
        // And never off the left or right edge either.
        tag.style.left = Math.max(2, -r.left + 4) + 'px';
        tag.style.maxWidth = Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px';
      }

      function usable(el) {
        return el && el !== frame && el !== edge && el !== document.documentElement &&
          el !== document.body && !(frame && frame.contains(el));
      }

      // The element going: it shrinks and fades as a puff of pink flies off
      // it, and only then is it told to stay gone.
      function burst(r) {
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var layer = document.createElement('div');
        layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;overflow:hidden';
        document.documentElement.appendChild(layer);
        var flash = document.createElement('div');
        flash.style.cssText = 'position:absolute;box-sizing:border-box;border-radius:8px;' +
          'left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;' +
          'background:rgba(' + PINK + ',.28);border:2px solid rgba(' + PINK + ',.9)';
        layer.appendChild(flash);
        if (flash.animate) {
          flash.animate([{ opacity: 1, transform: 'scale(1)' }, { opacity: 0, transform: 'scale(.9)' }],
            { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)', fill: 'forwards' });
        }
        var spread = Math.min(160, Math.max(48, Math.sqrt(r.width * r.height) / 2));
        for (var i = 0; i < 18; i++) {
          var dot = document.createElement('div');
          var size = 3 + Math.random() * 5;
          dot.style.cssText = 'position:absolute;border-radius:50%;' +
            'left:' + (cx - size / 2) + 'px;top:' + (cy - size / 2) + 'px;' +
            'width:' + size + 'px;height:' + size + 'px;' +
            'background:rgba(' + PINK + ',' + (0.6 + Math.random() * 0.4) + ')';
          layer.appendChild(dot);
          var angle = (Math.PI * 2 * i) / 18 + Math.random() * 0.4;
          var far = spread * (0.5 + Math.random() * 0.6);
          if (dot.animate) {
            dot.animate([
              { transform: 'translate(0,0) scale(1)', opacity: 1 },
              { transform: 'translate(' + Math.cos(angle) * far + 'px,' + Math.sin(angle) * far + 'px) scale(.2)', opacity: 0 }
            ], { duration: 420 + Math.random() * 180, easing: 'cubic-bezier(.15,.7,.3,1)', fill: 'forwards' });
          }
        }
        setTimeout(function () { layer.remove(); }, 700);
      }

      function fade(el) {
        var before = el.getAttribute('style');
        el.style.setProperty('transition', 'transform .22s cubic-bezier(.4,0,.6,1), opacity .2s ease-in, filter .22s', 'important');
        el.style.setProperty('transform-origin', 'center', 'important');
        el.style.setProperty('transform', 'scale(.94)', 'important');
        el.style.setProperty('opacity', '0', 'important');
        el.style.setProperty('filter', 'blur(3px)', 'important');
        return function () {
          if (before === null) el.removeAttribute('style'); else el.setAttribute('style', before);
        };
      }

      function zap(el) {
        var fam = wantsAll() ? family(el) : null;
        var message;
        var going = [el];
        if (fam) {
          going = Array.prototype.slice.call(fam.nodes, 0, 400);
          var kinds = steadyClasses(el);
          var kind = known[el.tagName.toLowerCase()] ||
            (kinds.length ? kinds[0].replace(/[-_]/g, ' ') : el.tagName.toLowerCase());
          message = { selector: fam.selector, label: 'All “' + kind + '” (' + fam.nodes.length + ')',
                      note: fam.selector };
        } else {
          message = { selector: selectorFor(el), label: name(el), note: shape(el) };
        }
        hideBox();
        var bursts = 0;
        going.forEach(function (one) {
          var o = one.getBoundingClientRect();
          if (bursts < 10 && o.width > 0 && o.bottom > 0 && o.top < window.innerHeight) { burst(o); bursts++; }
        });
        var backs = going.map(fade);
        setTimeout(function () {
          try {
            window.webkit.messageHandlers.officeVeil.postMessage(message);
          } catch (err) {
            window.webkit.messageHandlers.officeVeil.postMessage({ trouble: String(err) });
          }
          // Its own style back once the rule has it hidden, so ⌘Z brings
          // back the element as it was, not a faded one.
          setTimeout(function () {
            backs.forEach(function (back) { back(); });
          }, 500);
        }, 200);
      }

      var known = {
        nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar',
        form: 'Form', dialog: 'Dialog', video: 'Video', img: 'Image',
        button: 'Button', iframe: 'Embed', figure: 'Figure', table: 'Table'
      };

      // What it is, in the order a person would answer the question: what it
      // calls itself, then what kind of thing it is, then what it says.
      function name(el) {
        var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
        if (said && said.trim()) return clip(said.trim(), 40);
        var tagName = el.tagName.toLowerCase();
        if (known[tagName]) return known[tagName];
        var role = el.getAttribute && el.getAttribute('role');
        if (role) return role.charAt(0).toUpperCase() + role.slice(1);
        var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
        return text ? clip(text, 40) : tagName;
      }

      /// How big, and which corner. Two sidebars read alike; they are rarely
      /// the same shape in the same place.
      function shape(el) {
        var r = el.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var side = cx < window.innerWidth / 3 ? 'left'
                 : (cx > window.innerWidth * 2 / 3 ? 'right' : 'centre');
        var band = cy < window.innerHeight / 3 ? 'top'
                 : (cy > window.innerHeight * 2 / 3 ? 'bottom' : 'middle');
        return Math.round(r.width) + '×' + Math.round(r.height) + ' · ' + band + ' ' + side;
      }

      function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

      // A class worth hanging a rule on: a word, not a build artefact.
      function steady(c) {
        return /^[a-zA-Z][\\w-]{2,29}$/.test(c) && !/\\d{3,}/.test(c) &&
               !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
      }

      function unique(sel) {
        try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
      }

      function selectorFor(el) {
        if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);

        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'aria-label', 'name', 'role'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) {
            var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
            if (unique(s)) return s;
          }
        }

        var classes = (el.className && typeof el.className === 'string')
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
        if (classes.length) {
          var byClass = el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.');
          if (unique(byClass)) return byClass;
        }

        // Last resort: a path, anchored on the nearest thing with a name.
        var parts = [], node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node.id && unique('#' + CSS.escape(node.id))) {
            parts.unshift('#' + CSS.escape(node.id));
            break;
          }
          var tagName = node.tagName.toLowerCase();
          var parent = node.parentElement;
          if (!parent) { parts.unshift(tagName); break; }
          var kin = Array.prototype.filter.call(parent.children, function (c) {
            return c.tagName === node.tagName;
          });
          parts.unshift(kin.length > 1
            ? tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')'
            : tagName);
          node = parent;
        }
        return parts.join(' > ');
      }

      function onMove(e) {
        if (!live) return;
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!usable(el)) return hideBox();
        if (el !== target) trail = [];
        var changed = e.altKey !== flipped;
        flipped = e.altKey;
        // mousemove and pointermove both come for each step: the box is
        // drawn once unless something moved or ⌥ changed.
        if (!changed && el === target && frame && frame.style.opacity === '1') return;
        target = el;
        place(el);
      }

      // The box keeps up with a page that scrolls under it.
      function onScroll() {
        if (live && target && target.isConnected) place(target);
      }

      function onLeave(e) {
        if (live && !e.relatedTarget) hideBox();
      }

      // ↑ takes in what the element sits in, ↓ goes back; Return zaps it.
      function onAlt(e) {
        if (!live || e.key !== 'Alt') return;
        var now = e.type === 'keydown';
        if (now === flipped) return;
        flipped = now;
        if (target) place(target);
      }

      function onKey(e) {
        onAlt(e);
        if (!live || !target) return;
        if (e.key === 'ArrowUp') {
          var up = target.parentElement;
          if (usable(up)) { trail.push(target); target = up; place(up); }
        } else if (e.key === 'ArrowDown') {
          if (trail.length) { target = trail.pop(); place(target); }
        } else if (e.key === 'Enter') {
          var el = target; target = null; trail = [];
          zap(el);
        } else {
          return;
        }
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      // Everything a press can be, swallowed. Real pages act on pointerdown or
      // mousedown and are gone before a click ever completes — which looked
      // exactly like nothing happening.
      function swallow(e) {
        if (!live) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      function onPress(e) {
        if (!live) return;
        swallow(e);
        if (e.button !== undefined && e.button !== 0) return;
        // The pointer may have arrived without ever moving — a click on the
        // very first element under it, or a trackpad tap.
        var el = target || document.elementFromPoint(e.clientX, e.clientY);
        if (!usable(el)) return;
        target = null;
        trail = [];
        zap(el);
      }

      var presses = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click',
                     'dblclick', 'contextmenu', 'touchstart'];

      window.__officeVeil = {
        on: function () {
          if (live) return;
          live = true;
          chrome();
          edge.style.opacity = '1';
          sheet('office-zap-cursor').textContent =
            'html, html * { cursor: url("' + bolt + '") 12 12, crosshair !important; }';
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('pointermove', onMove, true);
          document.addEventListener('mouseout', onLeave, true);
          document.addEventListener('keydown', onKey, true);
          document.addEventListener('keyup', onAlt, true);
          window.addEventListener('scroll', onScroll, true);
          presses.forEach(function (kind) {
            document.addEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
        },
        off: function () {
          if (!live) return;
          live = false;
          target = null;
          trail = [];
          flipped = false;
          hideBox();
          if (edge) edge.style.opacity = '0';
          sheet('office-zap-cursor').textContent = '';
          document.removeEventListener('mousemove', onMove, true);
          document.removeEventListener('pointermove', onMove, true);
          document.removeEventListener('mouseout', onLeave, true);
          document.removeEventListener('keydown', onKey, true);
          document.removeEventListener('keyup', onAlt, true);
          window.removeEventListener('scroll', onScroll, true);
          presses.forEach(function (kind) {
            document.removeEventListener(kind, kind === 'pointerdown' ? onPress : swallow, true);
          });
          window.webkit.messageHandlers.officeVeil.postMessage({ off: true });
        },
        // One element, or every one like it (Search's toolbar says which).
        mode: function (m) {
          all = m === 'all';
          if (live && target) place(target);
        },
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          sheet('office-veil').textContent = css;
          sheet('office-peek').textContent = sel +
            ' { outline: 2px solid rgba(255,55,95,.95) !important; outline-offset: 2px !important; }';
          try {
            var el = document.querySelector(sel);
            if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          } catch (e) {}
        },
        unpeek: function (css) {
          sheet('office-veil').textContent = css;
          sheet('office-peek').textContent = '';
        }
      };
    })();
    """
}
