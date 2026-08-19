import Foundation

/// The page OBS shows as a Browser Source: the persona's portrait on a transparent
/// background, its jaw driven by the live audio level the app publishes.
///
/// Self-contained by necessity — a browser source has no other files to reach for — and
/// deliberately simple: one image, split into a still upper head and a jaw that drops
/// with the voice, plus an idle sway and occasional blink so a silent character still
/// looks alive. The state poll is cheap; the motion between polls is interpolated in
/// the browser so it stays smooth at any frame rate.
enum OverlayPage {

    static func html(token: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>Silicon Optimizer — Live persona</title>
        <style>
          :root { color-scheme: dark; }
          html, body {
            margin: 0; padding: 0; height: 100%;
            background: transparent;
            overflow: hidden;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          }
          #stage {
            position: relative; height: 100%; width: 100%;
            display: flex; align-items: center; justify-content: center;
          }
          #character {
            position: relative;
            width: min(80vw, 80vh); height: min(80vw, 80vh);
            will-change: transform;
          }
          .layer {
            position: absolute; inset: 0;
            background-position: center; background-repeat: no-repeat;
            background-size: contain;
            will-change: transform, clip-path;
          }
          /* The head above the mouth line stays put; the jaw below it moves. */
          #head { clip-path: inset(0 0 38% 0); }
          #jaw  { clip-path: inset(62% 0 0 0); transform-origin: 50% 62%; }
          #blink {
            position: absolute; left: 0; right: 0;
            top: 34%; height: 7%;
            background: transparent;
            backdrop-filter: brightness(0.35);
            opacity: 0; border-radius: 40%;
            will-change: opacity;
          }
          #placeholder {
            display: none;
            color: rgba(255,255,255,0.85);
            font-size: 2rem; font-weight: 600; letter-spacing: 0.01em;
            text-shadow: 0 2px 12px rgba(0,0,0,0.6);
          }
          #caption {
            position: absolute; left: 5%; right: 5%; bottom: 4%;
            text-align: center; color: #fff; font-size: 1.5rem; line-height: 1.35;
            text-shadow: 0 2px 10px rgba(0,0,0,0.85), 0 0 3px rgba(0,0,0,0.9);
            opacity: 0; transition: opacity 200ms ease;
          }
          @media (prefers-reduced-motion: reduce) {
            #character, .layer { transition: none !important; }
          }
        </style>
        </head>
        <body>
          <div id="stage">
            <div id="character">
              <div class="layer" id="head"></div>
              <div class="layer" id="jaw"></div>
              <div id="blink"></div>
            </div>
            <div id="placeholder">No persona selected</div>
          </div>
          <div id="caption"></div>

        <script>
        const TOKEN = "\(token)";
        const character = document.getElementById('character');
        const head = document.getElementById('head');
        const jaw = document.getElementById('jaw');
        const blink = document.getElementById('blink');
        const caption = document.getElementById('caption');
        const placeholder = document.getElementById('placeholder');

        let target = 0, level = 0, speaking = false;
        let portraitVersion = -1, hasPortrait = false;
        let nextBlink = performance.now() + 2000 + Math.random() * 3000;

        async function poll() {
          try {
            const response = await fetch('/overlay/state?token=' + TOKEN, { cache: 'no-store' });
            if (response.ok) {
              const state = await response.json();
              target = Math.max(0, Math.min(1, state.level || 0));
              speaking = !!state.speaking;
              if (state.portraitVersion !== portraitVersion) {
                portraitVersion = state.portraitVersion;
                const url = 'url("/overlay/portrait?token=' + TOKEN + '&v=' + portraitVersion + '")';
                head.style.backgroundImage = url;
                jaw.style.backgroundImage = url;
                hasPortrait = portraitVersion > 0;
                placeholder.style.display = hasPortrait ? 'none' : 'block';
                placeholder.textContent = state.name || 'No persona selected';
              }
              caption.textContent = state.caption || '';
              caption.style.opacity = state.caption ? 1 : 0;
            }
          } catch (error) {
            // The app being restarted is routine; keep animating and try again.
          }
          setTimeout(poll, 80);
        }

        function frame(now) {
          // Chase the target: fast to open, slower to close, which is how a mouth moves.
          const speed = target > level ? 0.45 : 0.2;
          level += (target - level) * speed;
          if (!speaking) level *= 0.85;

          const drop = level * 5.5;                     // percent of the frame
          jaw.style.transform =
            'translateY(' + drop + '%) scaleY(' + (1 + level * 0.06) + ')';

          const sway = Math.sin(now / 1400) * 0.7 + level * 1.2;
          const breath = Math.sin(now / 2600) * 0.5;
          character.style.transform =
            'translateY(' + (breath - level * 0.8) + '%) rotate(' + sway * 0.25 + 'deg)';

          if (now > nextBlink) {
            blink.style.opacity = 1;
            setTimeout(() => { blink.style.opacity = 0; }, 110);
            nextBlink = now + 2200 + Math.random() * 4000;
          }
          requestAnimationFrame(frame);
        }

        poll();
        requestAnimationFrame(frame);
        </script>
        </body>
        </html>
        """
    }
}
