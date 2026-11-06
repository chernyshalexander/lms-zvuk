/* Classic web UI: open the wave settings as an overlay on the current page
   instead of the new browser tab the skin gives a weblink item.
   Injected into the skin's main JS bundle by Plugins::Zvuk::Plugin.

   The skin renders a weblink item as <a target="_blank">, which opens a stray
   tab; here the click is turned into an overlay on the current page. */
(function () {
	// Always active in the classic web UI. The material_settings_mode preference
	// is scoped to Material by its own label, so it does not gate this behaviour.
	var CLOSE_LABEL = '[% "PLUGIN_ZVUK_CANCEL" | string %]';
	var DIALOG_LABEL = '[% "PLUGIN_ZVUK_WAVE_SLIDERS" | string %]';
	var overlay = null;
	var frame = null;
	var lastFocused = null;

	function buildStyles() {
		var css = ''
			+ '.zvuk-modal-overlay{position:fixed;inset:0;z-index:2000;background:rgba(0,0,0,.55);'
			+ 'display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box;}'
			+ '.zvuk-modal-dialog{position:relative;width:100%;max-width:640px;max-height:100%;'
			+ 'background:#fff;border-radius:10px;overflow:hidden;display:flex;flex-direction:column;'
			+ 'box-shadow:0 12px 40px rgba(0,0,0,.35);}'
			+ '.zvuk-modal-dialog iframe{display:block;width:100%;height:78vh;border:0;background:#fff;}'
			+ '.zvuk-modal-close{position:absolute;top:8px;right:8px;width:30px;height:30px;'
			+ 'border:0;border-radius:7px;background:rgba(0,0,0,.06);color:#333;font-size:18px;'
			+ 'line-height:1;cursor:pointer;}'
			+ '.zvuk-modal-close:hover{background:rgba(0,0,0,.12);}'
			+ '.zvuk-modal-close:focus-visible{outline:2px solid #43a047;outline-offset:2px;}'
			+ 'body.zvuk-modal-open{overflow:hidden;}';

		var style = document.createElement('style');
		style.id = 'zvuk-modal-styles';
		style.appendChild(document.createTextNode(css));
		document.head.appendChild(style);
	}

	function closeModal() {
		if (!overlay) {
			return;
		}
		overlay.parentNode && overlay.parentNode.removeChild(overlay);
		overlay = null;
		frame = null;
		document.body.classList.remove('zvuk-modal-open');
		document.removeEventListener('keydown', onKeydown, true);
		if (lastFocused && lastFocused.focus) {
			lastFocused.focus();
		}
		lastFocused = null;
	}

	// The embedded page calls this after a successful save
	window.zvukCloseWaveModal = closeModal;

	function onKeydown(event) {
		if (event.key === 'Escape' || event.keyCode === 27) {
			event.preventDefault();
			closeModal();
		}
	}

	function openModal(url) {
		if (overlay) {
			return;
		}
		if (!document.getElementById('zvuk-modal-styles')) {
			buildStyles();
		}

		lastFocused = document.activeElement;

		overlay = document.createElement('div');
		overlay.className = 'zvuk-modal-overlay';
		overlay.addEventListener('click', function (event) {
			if (event.target === overlay) {
				closeModal();
			}
		});

		var dialog = document.createElement('div');
		dialog.className = 'zvuk-modal-dialog';
		dialog.setAttribute('role', 'dialog');
		dialog.setAttribute('aria-modal', 'true');
	dialog.setAttribute('aria-label', DIALOG_LABEL);

		var closeBtn = document.createElement('button');
		closeBtn.type = 'button';
		closeBtn.className = 'zvuk-modal-close';
		closeBtn.setAttribute('aria-label', CLOSE_LABEL);
		closeBtn.title = CLOSE_LABEL;
		closeBtn.appendChild(document.createTextNode('\u00d7'));
		closeBtn.addEventListener('click', closeModal);

		frame = document.createElement('iframe');
		frame.title = DIALOG_LABEL;
		frame.setAttribute('allowtransparency', 'true');
		frame.src = url + (url.indexOf('?') === -1 ? '?' : '&') + 'embed=1';

		dialog.appendChild(closeBtn);
		dialog.appendChild(frame);
		overlay.appendChild(dialog);
		document.body.appendChild(overlay);
		document.body.classList.add('zvuk-modal-open');
		document.addEventListener('keydown', onKeydown, true);
		closeBtn.focus();
	}

	// Capture phase: the skin may also bind its own handler to the anchor.
	// The classic skin renders its menu inside same-origin iframes (home.html in
	// #leftcontent), and events from an iframe never reach the parent document,
	// so the same listener has to be attached inside every frame and reattached
	// whenever that frame navigates.
	function handleClick(event) {
		var doc = event.currentTarget;
		var node = event.target;
		while (node && node !== doc) {
			if (node.tagName === 'A' && node.getAttribute) {
				var href = node.getAttribute('href') || '';
				if (href.indexOf('/plugins/zvuk/waveStandalone') !== -1) {
					event.preventDefault();
					event.stopPropagation();
					openModal(href);
					return;
				}
			}
			node = node.parentNode;
		}
	}

	function bindDocument(doc) {
		if (!doc || doc.__zvukWaveModalBound) {
			return;
		}
		doc.__zvukWaveModalBound = true;
		doc.addEventListener('click', handleClick, true);
		doc.addEventListener('keydown', onKeydown, true);
	}

	function bindFrames() {
		var frames = document.querySelectorAll('iframe');
		for (var i = 0; i < frames.length; i++) {
			var frameEl = frames[i];
			try { bindDocument(frameEl.contentDocument); } catch (e) {}
			if (!frameEl.__zvukWaveModalBound) {
				frameEl.__zvukWaveModalBound = true;
				// fires on every navigation inside the frame
				frameEl.addEventListener('load', function () {
					try { bindDocument(this.contentDocument); } catch (e) {}
				});
			}
		}
	}

	bindDocument(document);
	bindFrames();
	if (window.addEventListener) {
		window.addEventListener('load', bindFrames);
	}
	// the skin may create or replace the browsing frame after load
	if (window.MutationObserver) {
		new MutationObserver(bindFrames).observe(document.documentElement, {
			childList: true,
			subtree: true
		});
	}
})();
