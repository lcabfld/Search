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
      // Zap, as Arc has it. Pointing outlines what is under the pointer;
      // a click chooses it, tints it and everything related to it, and puts
      // a card beside it: Zap this, Zap all related elements — a button that
      // is also a slider, dragged to say how far "related" reaches — and
      // Cancel, over the count and the rule that would be written.
      var frame = null, tag = null, edge = null, card = null, target = null, live = false;
      // What was clicked, while its card is up.
      var chosen = null;
      // The elements ↑ walked out of, for ↓ to walk back into.
      var trail = [];
      var TINT = '255,196,0';
      var HOT = '255,138,0';
      // How far "related" reaches, 0 the narrowest family the element is
      // in, 1 every element with its tag (see ladder).
      var reach = 0;
      // The ladder last worked out, kept for the element it was for.
      var cached = null;
      // The family's other boxes, drawn from a pool so a page of a hundred
      // headlines isn't a hundred new elements on every move.
      var pool = [];
      // A press on the slider, until it is let go.
      var sliding = null;
      var FONT = '-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif';

      var bolt = 'data:image/svg+xml,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">' +
        '<path d="M13.5 1.5 4 13.5h6.5L9 22.5l10-12.5h-6.6z" fill="rgb(' + HOT + ')" ' +
        'stroke="white" stroke-width="1.6" stroke-linejoin="round"/></svg>');

      function important(el, css) {
        css.split(';').forEach(function (rule) {
          var at = rule.indexOf(':');
          if (at < 0) return;
          el.style.setProperty(rule.slice(0, at).trim(), rule.slice(at + 1).trim(), 'important');
        });
      }

      function chrome() {
        if (frame) return frame;
        frame = document.createElement('div');
        important(frame, 'position:fixed;z-index:2147483646;pointer-events:none;box-sizing:border-box;' +
          'border:2px solid rgba(' + HOT + ',.95);background:rgba(' + TINT + ',.16);' +
          'border-radius:6px;opacity:0;margin:0;padding:0;' +
          'transition:left .12s cubic-bezier(.2,.8,.2,1),top .12s cubic-bezier(.2,.8,.2,1),' +
          'width .12s cubic-bezier(.2,.8,.2,1),height .12s cubic-bezier(.2,.8,.2,1),opacity .1s,background .15s');
        tag = document.createElement('div');
        important(tag, 'position:absolute;display:flex;align-items:center;gap:6px;margin:0;' +
          'font:600 11px ' + FONT + ';letter-spacing:-.01em;color:#1a1200;' +
          'background:rgb(' + TINT + ');padding:3px 8px;border-radius:6px;white-space:nowrap;' +
          'overflow:hidden;text-overflow:ellipsis;box-shadow:0 2px 8px rgba(0,0,0,.18)');
        frame.appendChild(tag);
        edge = document.createElement('div');
        important(edge, 'position:fixed;inset:0;z-index:2147483645;pointer-events:none;' +
          'box-shadow:inset 0 0 0 3px rgba(' + HOT + ',.8),inset 0 0 40px rgba(' + TINT + ',.14);' +
          'opacity:0;transition:opacity .2s');
        document.documentElement.appendChild(edge);
        document.documentElement.appendChild(frame);
        return frame;
      }

      function hidePool() {
        for (var i = 0; i < pool.length; i++) pool[i].style.setProperty('display', 'none', 'important');
      }

      function hideBox() {
        if (frame) frame.style.setProperty('opacity', '0', 'important');
        hidePool();
      }

      function poolBox(i) {
        if (pool[i]) return pool[i];
        var b = document.createElement('div');
        important(b, 'position:fixed;z-index:2147483646;pointer-events:none;box-sizing:border-box;' +
          'border:1.5px solid rgba(' + HOT + ',.8);background:rgba(' + TINT + ',.38);' +
          'border-radius:5px;display:none;margin:0;padding:0');
        document.documentElement.appendChild(b);
        pool[i] = b;
        return b;
      }

      function boxOver(box, r) {
        box.style.setProperty('left', (r.left - 2) + 'px', 'important');
        box.style.setProperty('top', (r.top - 2) + 'px', 'important');
        box.style.setProperty('width', (r.width + 4) + 'px', 'important');
        box.style.setProperty('height', (r.height + 4) + 'px', 'important');
      }

      // Pointing: the one outline, with what it is and how big.
      function place(el) {
        var box = chrome(), r = el.getBoundingClientRect();
        hidePool();
        if (r.width < 1 || r.height < 1) return hideBox();
        var radius = 6;
        try { radius = Math.max(4, parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0); } catch (e) {}
        box.style.setProperty('opacity', '1', 'important');
        box.style.setProperty('background', 'rgba(' + TINT + ',.16)', 'important');
        boxOver(box, r);
        box.style.setProperty('border-radius', Math.min(radius + 2, 24) + 'px', 'important');
        tag.innerHTML = '';
        var label = document.createElement('span');
        label.textContent = name(el);
        var dims = document.createElement('span');
        dims.textContent = Math.round(r.width) + ' × ' + Math.round(r.height);
        dims.style.setProperty('opacity', '.6', 'important');
        tag.appendChild(label);
        tag.appendChild(dims);
        tag.style.setProperty('display', 'flex', 'important');
        tag.style.setProperty('top', (r.top >= 28 ? -25 : 4) + 'px', 'important');
        tag.style.setProperty('left', Math.max(2, -r.left + 4) + 'px', 'important');
        tag.style.setProperty('max-width', Math.max(80, window.innerWidth - Math.max(0, r.left) - 16) + 'px', 'important');
      }

      // The families above the element alone: the slider's range.
      function related(el) {
        return ladder(el).filter(function (r) { return r.nodes.length > 1; });
      }

      function rungAt(el) {
        var rungs = related(el);
        if (!rungs.length) return null;
        return rungs[Math.round(reach * (rungs.length - 1))];
      }

      // Chosen: the element and the family the slider is on, tinted.
      function tint() {
        if (!chosen) return;
        var box = chrome(), r = chosen.getBoundingClientRect();
        tag.style.setProperty('display', 'none', 'important');
        box.style.setProperty('opacity', '1', 'important');
        box.style.setProperty('background', 'rgba(' + TINT + ',.45)', 'important');
        boxOver(box, r);
        hidePool();
        var rung = rungAt(chosen);
        if (rung) {
          var drawn = 0;
          for (var j = 0; j < rung.nodes.length && drawn < 300; j++) {
            var other = rung.nodes[j];
            if (other === chosen) continue;
            var o = other.getBoundingClientRect();
            if (o.width < 1 || o.height < 1 || o.bottom < 0 || o.top > window.innerHeight) continue;
            var b = poolBox(drawn++);
            b.style.setProperty('display', 'block', 'important');
            boxOver(b, o);
          }
        }
        fillCard(rung);
      }

      function el(kind, css, text) {
        var e = document.createElement(kind);
        important(e, 'all:initial;box-sizing:border-box;font-family:' + FONT + ';' + css);
        if (text) e.textContent = text;
        return e;
      }

      var parts = {};

      function makeCard() {
        if (card) return card;
        card = el('div', 'position:fixed;z-index:2147483647;display:flex;flex-direction:column;gap:8px;' +
          'padding:8px;border-radius:16px;background:rgba(242,242,242,.88);' +
          '-webkit-backdrop-filter:blur(24px) saturate(1.8);backdrop-filter:blur(24px) saturate(1.8);' +
          'box-shadow:0 18px 48px rgba(0,0,0,.24),0 0 0 .5px rgba(0,0,0,.14),inset 0 .5px 0 rgba(255,255,255,.8);' +
          'opacity:0;transform:translateY(4px) scale(.98);transition:opacity .14s,transform .18s cubic-bezier(.2,.8,.2,1);' +
          'cursor:default;width:min(520px,calc(100vw - 24px))');
        var row = el('div', 'display:flex;gap:8px;align-items:stretch');
        var button = 'display:flex;align-items:center;justify-content:center;height:40px;padding:0 15px;' +
          'border-radius:11px;font-size:15px;font-weight:500;color:#fff;white-space:nowrap;cursor:pointer;' +
          'box-shadow:inset 0 .5px 0 rgba(255,255,255,.35),0 1px 2px rgba(0,0,0,.12)';
        parts.one = el('div', button + ';background:linear-gradient(#ff4b45,#ec2018)', 'Zap this');
        parts.one.setAttribute('data-zap', 'one');
        parts.all = el('div', button + ';position:relative;flex:1;overflow:hidden;justify-content:flex-start;' +
          'background:linear-gradient(#a3a3a3,#8f8f8f);cursor:ew-resize');
        parts.all.setAttribute('data-zap', 'all');
        parts.fill = el('div', 'position:absolute;left:0;top:0;bottom:0;width:0;' +
          'background:linear-gradient(90deg,#ffa31a,#ff8a00);transition:width .08s');
        parts.label = el('div', 'position:relative;color:#fff;font-size:15px;font-weight:500;' +
          'text-shadow:0 1px 1px rgba(0,0,0,.12);white-space:nowrap;overflow:hidden;text-overflow:ellipsis', 'Zap all related elements');
        parts.all.appendChild(parts.fill);
        parts.all.appendChild(parts.label);
        parts.cancel = el('div', button + ';background:linear-gradient(#6e6e6e,#5c5c5c)', 'Cancel');
        parts.cancel.setAttribute('data-zap', 'cancel');
        row.appendChild(parts.one);
        row.appendChild(parts.all);
        row.appendChild(parts.cancel);
        var info = el('div', 'display:flex;gap:10px;align-items:baseline;padding:2px 8px 4px;min-width:0');
        parts.count = el('div', 'font-size:12.5px;font-weight:600;color:#6b6b6b;flex:none;font-variant-numeric:tabular-nums');
        parts.rule = el('div', 'font:12.5px ui-monospace,"SF Mono",Menlo,monospace;color:#8a8a8a;' +
          'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0;flex:1');
        info.appendChild(parts.count);
        info.appendChild(parts.rule);
        card.appendChild(row);
        card.appendChild(info);
        document.documentElement.appendChild(card);
        return card;
      }

      function fillCard(rung) {
        makeCard();
        var none = !rung;
        parts.all.style.setProperty('opacity', none ? '.45' : '1', 'important');
        parts.all.style.setProperty('cursor', none ? 'default' : 'ew-resize', 'important');
        parts.fill.style.setProperty('width', none ? '0' : (8 + reach * 92) + '%', 'important');
        parts.label.textContent = none ? 'Nothing else like it' : 'Zap all related elements';
        parts.count.textContent = rung ? String(rung.nodes.length) : '1';
        parts.rule.textContent = rung ? rung.selector : selectorFor(chosen);
      }

      // Under the element if there is room, over it if not, and inside the
      // window either way.
      function placeCard() {
        if (!chosen) return;
        var c = makeCard(), r = chosen.getBoundingClientRect();
        var w = c.offsetWidth, h = c.offsetHeight;
        var top = r.bottom + 10;
        if (top + h > window.innerHeight - 12) top = r.top - h - 10;
        if (top < 12) top = Math.min(window.innerHeight - h - 24, Math.max(12, r.top + 12));
        var left = r.left + r.width / 2 - w / 2;
        left = Math.max(12, Math.min(left, window.innerWidth - w - 12));
        c.style.setProperty('top', top + 'px', 'important');
        c.style.setProperty('left', left + 'px', 'important');
      }

      function choose(element) {
        chosen = element;
        trail = [];
        // Start on the narrowest family, as Arc does: a little of the bar.
        reach = 0;
        makeCard();
        tint();
        placeCard();
        card.style.setProperty('display', 'flex', 'important');
        requestAnimationFrame(function () {
          card.style.setProperty('opacity', '1', 'important');
          card.style.setProperty('transform', 'none', 'important');
        });
      }

      function unchoose() {
        chosen = null;
        sliding = null;
        cached = null;
        if (card) {
          card.style.setProperty('opacity', '0', 'important');
          card.style.setProperty('transform', 'translateY(4px) scale(.98)', 'important');
          card.style.setProperty('display', 'none', 'important');
        }
        hideBox();
      }

      function inCard(node) { return !!(card && node && card.contains(node)); }

      function usable(node) {
        return node && node !== frame && node !== edge && node !== document.documentElement &&
          node !== document.body && !(frame && frame.contains(node)) && !inCard(node) &&
          pool.indexOf(node) === -1;
      }

      function zap(element, rung) {
        var message;
        var going = [element];
        if (rung) {
          going = Array.prototype.slice.call(rung.nodes, 0, 400);
          var kinds = steadyClasses(element);
          var kind = known[element.tagName.toLowerCase()] ||
            (kinds.length ? kinds[0].replace(/[-_]/g, ' ') : element.tagName.toLowerCase());
          message = { selector: rung.selector, label: 'All “' + kind + '” (' + rung.nodes.length + ')', note: rung.selector };
        } else {
          message = { selector: selectorFor(element), label: name(element), note: shape(element) };
        }
        unchoose();
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
          // Their own style back once the rule has them hidden, so ⌘Z
          // brings them back as they were, not faded.
          setTimeout(function () { backs.forEach(function (back) { back(); }); }, 500);
        }, 200);
      }

      function slideTo(x) {
        var r = parts.all.getBoundingClientRect();
        var next = Math.max(0, Math.min(1, (x - r.left - r.width * 0.08) / (r.width * 0.92)));
        var rungs = related(chosen);
        // Stepped, so the bar lands where a family is.
        if (rungs.length > 1) next = Math.round(next * (rungs.length - 1)) / (rungs.length - 1);
        else next = 0;
        if (next !== reach) { reach = next; tint(); }
      }

      function onMove(e) {
        if (!live) return;
        if (sliding) {
          if (Math.abs(e.clientX - sliding.x) > 3) sliding.moved = true;
          if (sliding.moved) slideTo(e.clientX);
          return;
        }
        if (chosen) return;
        var node = document.elementFromPoint(e.clientX, e.clientY);
        if (!usable(node)) return hideBox();
        if (node !== target) trail = [];
        // mousemove and pointermove both come for each step: the box is
        // drawn once unless the pointer is on something new.
        if (node === target && frame && frame.style.opacity === '1') return;
        target = node;
        place(node);
      }

      // The boxes and the card keep up with a page that scrolls under them.
      function onScroll() {
        if (!live) return;
        if (chosen) { tint(); placeCard(); }
        else if (target && target.isConnected) place(target);
      }

      function onLeave(e) {
        if (live && !chosen && !e.relatedTarget) hideBox();
      }

      // ↑ takes in what the element sits in, ↓ goes back; Return chooses
      // it, and Return again zaps it alone.
      function onKey(e) {
        if (!live) return;
        var current = chosen || target;
        if (!current) return;
        if (e.key === 'ArrowUp') {
          var up = current.parentElement;
          if (!usable(up)) return stop(e);
          trail.push(current);
          if (chosen) { var keep = trail; choose(up); trail = keep; } else { target = up; place(up); }
        } else if (e.key === 'ArrowDown') {
          if (!trail.length) return stop(e);
          var down = trail.pop();
          if (chosen) { var kept = trail; choose(down); trail = kept; } else { target = down; place(down); }
        } else if (e.key === 'Enter') {
          if (chosen) zap(chosen, null); else choose(current);
        } else {
          return;
        }
        stop(e);
      }

      function stop(e) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      // Everything a press can be, swallowed. Real pages act on pointerdown or
      // mousedown and are gone before a click ever completes — which looked
      // exactly like nothing happening.
      function swallow(e) {
        if (!live) return;
        stop(e);
      }

      function onPress(e) {
        if (!live) return;
        stop(e);
        if (e.button !== undefined && e.button !== 0) return;
        var hit = e.target && e.target.closest ? e.target.closest('[data-zap]') : null;
        if (hit && inCard(hit)) {
          var what = hit.getAttribute('data-zap');
          if (what === 'one') zap(chosen, null);
          else if (what === 'cancel') unchoose();
          else if (what === 'all' && rungAt(chosen)) {
            sliding = { x: e.clientX, moved: false };
            slideTo(e.clientX);
          }
          return;
        }
        if (inCard(e.target)) return;
        // A click away from the card chooses again, or puts it away.
        var node = document.elementFromPoint(e.clientX, e.clientY);
        if (chosen) {
          if (usable(node) && node !== chosen) { choose(node); } else { unchoose(); }
          return;
        }
        node = target || node;
        if (!usable(node)) return;
        target = null;
        choose(node);
      }

      function onRelease(e) {
        if (!live) return;
        stop(e);
        if (!sliding) return;
        var tapped = !sliding.moved;
        sliding = null;
        // A click on the bar zaps the family it shows; a drag only sets it.
        if (tapped && chosen) zap(chosen, rungAt(chosen));
      }

      var presses = ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'touchstart'];


      function sheet(id) {
        var s = document.getElementById(id);
        if (!s) {
          s = document.createElement('style');
          s.id = id;
          (document.head || document.documentElement).appendChild(s);
        }
        return s;
      }

      function matches(sel) {
        try { return document.querySelectorAll(sel); } catch (e) { return []; }
      }

      function steadyClasses(el) {
        return (el.className && typeof el.className === 'string')
          ? el.className.trim().split(/\\s+/).filter(steady) : [];
      }

      // Every way of naming this element and the ones like it, from the one
      // element alone to every element with its tag: all its classes, a test
      // hook, each class, its tag inside the nearest ancestor with a name,
      // its tag under its parent, the tag itself. Each rung finds more than
      // the one below it; two that find as many are one rung, the narrower
      // name kept.
      function ladder(el) {
        if (cached && cached.el === el) return cached.rungs;
        var tagName = el.tagName.toLowerCase();
        var classes = steadyClasses(el);
        var tries = [selectorFor(el)];
        if (classes.length > 1) tries.push(tagName + '.' + classes.map(CSS.escape).join('.'));
        var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'data-component', 'data-type', 'itemprop', 'role'];
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute && el.getAttribute(hooks[i]);
          if (v) tries.push(tagName + '[' + hooks[i] + '="' + CSS.escape(v) + '"]');
        }
        classes.forEach(function (c) { tries.push(tagName + '.' + CSS.escape(c)); });
        var node = el.parentElement, depth = 0;
        while (node && node !== document.body && node !== document.documentElement && depth < 6) {
          var anchor = null;
          if (node.id && unique('#' + CSS.escape(node.id))) anchor = '#' + CSS.escape(node.id);
          else {
            var ac = steadyClasses(node);
            if (ac.length) anchor = node.tagName.toLowerCase() + '.' + CSS.escape(ac[0]);
          }
          if (anchor) {
            if (classes.length) tries.push(anchor + ' ' + tagName + '.' + CSS.escape(classes[0]));
            tries.push(anchor + ' ' + tagName);
            break;
          }
          node = node.parentElement;
          depth++;
        }
        tries.push(tagName);
        var rungs = [];
        var seen = {};
        tries.forEach(function (sel, order) {
          if (seen[sel]) return;
          seen[sel] = true;
          var found = matches(sel);
          if (!found.length || Array.prototype.indexOf.call(found, el) === -1) return;
          rungs.push({ selector: sel, nodes: found, order: order });
        });
        rungs.sort(function (a, b) { return a.nodes.length - b.nodes.length || a.order - b.order; });
        var kept = [];
        rungs.forEach(function (r) {
          if (!kept.length || kept[kept.length - 1].nodes.length !== r.nodes.length) kept.push(r);
        });
        cached = { el: el, rungs: kept };
        return kept;
      }

      // The element going: it shrinks and fades as a puff of orange flies off
      // it, and only then is it told to stay gone.
      function burst(r) {
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var layer = document.createElement('div');
        layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;overflow:hidden';
        document.documentElement.appendChild(layer);
        var flash = document.createElement('div');
        flash.style.cssText = 'position:absolute;box-sizing:border-box;border-radius:8px;' +
          'left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;' +
          'background:rgba(' + HOT + ',.28);border:2px solid rgba(' + HOT + ',.9)';
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
            'background:rgba(' + HOT + ',' + (0.6 + Math.random() * 0.4) + ')';
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

      window.__officeVeil = {
        on: function () {
          if (live) return;
          live = true;
          chrome();
          edge.style.setProperty('opacity', '1', 'important');
          sheet('office-zap-cursor').textContent =
            'html, html * { cursor: url("' + bolt + '") 12 12, crosshair !important; }';
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('pointermove', onMove, true);
          document.addEventListener('mouseout', onLeave, true);
          document.addEventListener('keydown', onKey, true);
          document.addEventListener('pointerdown', onPress, true);
          document.addEventListener('pointerup', onRelease, true);
          window.addEventListener('scroll', onScroll, true);
          presses.forEach(function (kind) { document.addEventListener(kind, swallow, true); });
        },
        off: function () {
          if (!live) return;
          live = false;
          target = null;
          trail = [];
          unchoose();
          if (edge) edge.style.setProperty('opacity', '0', 'important');
          sheet('office-zap-cursor').textContent = '';
          document.removeEventListener('mousemove', onMove, true);
          document.removeEventListener('pointermove', onMove, true);
          document.removeEventListener('mouseout', onLeave, true);
          document.removeEventListener('keydown', onKey, true);
          document.removeEventListener('pointerdown', onPress, true);
          document.removeEventListener('pointerup', onRelease, true);
          window.removeEventListener('scroll', onScroll, true);
          presses.forEach(function (kind) { document.removeEventListener(kind, swallow, true); });
          window.webkit.messageHandlers.officeVeil.postMessage({ off: true });
        },
        // Show one hidden thing for as long as the pointer rests on its row.
        // The stylesheet is rebuilt without that one selector rather than
        // fighting it with another rule, so the element comes back with the
        // layout it actually had.
        peek: function (css, sel) {
          sheet('office-veil').textContent = css;
          sheet('office-peek').textContent = sel +
            ' { outline: 2px solid rgba(255,138,0,.95) !important; outline-offset: 2px !important; }';
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
