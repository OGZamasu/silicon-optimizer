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
          /* Everything below the lips stretches about the lip line; everything above
             is drawn over it untouched. They share the anchor row exactly, so the join
             never shows — slicing the face into two slabs left a visible hairline. */
          #jaw  { z-index: 1; }
          #head { z-index: 2; }
          /* The second drawing, when the artist made one, simply crosses in. */
          #open { z-index: 3; opacity: 0; }
          #eyes { z-index: 4; opacity: 0; }
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
              <div class="layer" id="jaw"></div>
              <div class="layer" id="head"></div>
              <div class="layer" id="open"></div>
              <div class="layer" id="eyes"></div>
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
        const open = document.getElementById('open');
        const eyes = document.getElementById('eyes');
        const blink = document.getElementById('blink');
        const caption = document.getElementById('caption');
        const placeholder = document.getElementById('placeholder');

        let target = 0, level = 0, speaking = false;
        let portraitVersion = -1, hasPortrait = false;
        let mouthTop = 0.66, hasOpenMouth = false, hasClosedEyes = false;
        // Live face tracking, when it is running: head pose and expressions read
        // from the camera. Polled straight from the tracker so head motion is not
        // waiting on anything else, and ignored entirely when it goes quiet.
        let trackerURL = '';
        let track = null, trackFresh = 0;
        let headYaw = 0, headPitch = 0, headRoll = 0, blinkNow = 0, browNow = 0;
        let bodyLean = 0, bodyTilt = 0;
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
                mouthTop = state.mouthTop || 0.66;
                hasOpenMouth = !!state.hasOpenMouth;
                hasClosedEyes = !!state.hasClosedEyes;
                eyes.style.backgroundImage = hasClosedEyes
                  ? 'url("/overlay/portrait-eyes?token=' + TOKEN + '&v=' + portraitVersion + '")'
                  : 'none';
                const url = 'url("/overlay/portrait?token=' + TOKEN + '&v=' + portraitVersion + '")';
                head.style.backgroundImage = url;
                jaw.style.backgroundImage = url;
                open.style.backgroundImage = hasOpenMouth
                  ? 'url("/overlay/portrait-open?token=' + TOKEN + '&v=' + portraitVersion + '")'
                  : 'none';
                // The head is clipped at the lips; the jaw is the whole image, stretched
                // about that same line, so the two always meet on an identical row.
                head.style.clipPath = 'inset(0 0 ' + ((1 - mouthTop) * 100) + '% 0)';
                jaw.style.transformOrigin = '50% ' + (mouthTop * 100) + '%';
                hasPortrait = portraitVersion > 0;
                placeholder.style.display = hasPortrait ? 'none' : 'block';
                placeholder.textContent = state.name || 'No persona selected';
              }
              trackerURL = state.trackerURL || '';
              caption.textContent = state.caption || '';
              caption.style.opacity = state.caption ? 1 : 0;
            }
          } catch (error) {
            // The app being restarted is routine; keep animating and try again.
          }
          setTimeout(poll, 80);
        }

        // Tracking is polled on its own clock, much faster than the app state:
        // a head that updates twelve times a second reads as a stutter, and this
        // costs nothing but a localhost round trip.
        async function pollTracking() {
          if (trackerURL) {
            try {
              const response = await fetch(trackerURL, { cache: 'no-store' });
              if (response.ok) {
                const data = await response.json();
                if (data.tracking) {
                  track = data;
                  trackFresh = performance.now();
                }
              }
            } catch (error) {
              track = null;   // Tracker stopped; fall back to the voice.
            }
          } else {
            track = null;
          }
          setTimeout(pollTracking, 33);
        }

        function frame(now) {
          // Tracking outranks the voice: if the camera can see a mouth, that is the
          // mouth to draw. Stale tracking (older than half a second) is ignored so a
          // stopped tracker leaves the character speaking rather than frozen.
          const live = track && (now - trackFresh) < 500;
          if (live) target = Math.max(0, Math.min(1, track.mouthOpen * 1.6));

          // Chase the target: fast to open, slower to close, which is how a mouth moves.
          const speed = target > level ? 0.45 : 0.2;
          level += (target - level) * speed;
          if (!speaking && !live) level *= 0.85;

          // Head pose, eased so the character glides rather than snapping between
          // samples. Angles are damped: a full head turn on camera reads as far too
          // much on a flat drawing.
          const wantYaw = live ? track.yaw * 0.35 : 0;
          const wantPitch = live ? track.pitch * 0.3 : 0;
          const wantRoll = live ? track.roll * 0.5 : 0;
          const wantLean = live && track.body ? track.lean * 6 : 0;
          const wantTilt = live && track.body ? track.shoulderTilt * 0.3 : 0;
          bodyLean += (wantLean - bodyLean) * 0.2;
          bodyTilt += (wantTilt - bodyTilt) * 0.2;
          headYaw += (wantYaw - headYaw) * 0.25;
          headPitch += (wantPitch - headPitch) * 0.25;
          headRoll += (wantRoll - headRoll) * 0.25;
          browNow += ((live ? track.browRaise : 0) - browNow) * 0.25;

          if (hasOpenMouth) {
            open.style.opacity = Math.min(1, level * 1.4);
            jaw.style.transform = 'none';
          } else {
            // Stretch the lower face about the lip line: the chin travels, the mouth
            // opens, and the anchor row stays put.
            const stretch = 1 + level * 0.09 / Math.max(0.1, 1 - mouthTop);
            jaw.style.transform = 'scaleY(' + stretch + ')';
          }

          // Idle breathing only — tying the body to loudness makes a character lurch
          // on every syllable. Speech belongs in the mouth. Under tracking the head
          // carries the movement instead, and idle motion steps aside.
          const sway = live ? 0 : Math.sin(now / 1400) * 0.7;
          const breath = live ? 0 : Math.sin(now / 2600) * 0.5;
          character.style.transform =
            'translateY(' + (breath - headPitch * 0.25 - browNow * 0.6) + '%) '
            + 'translateX(' + (headYaw * 0.35 + bodyLean) + '%) '
            + 'rotate(' + (sway * 0.25 + headRoll + bodyTilt) + 'deg)';

          // Blinking: the camera's when it can see one, the clock's when it cannot,
          // because a character that never blinks looks embalmed.
          if (live) {
            blinkNow += (track.blink - blinkNow) * 0.5;
            if (hasClosedEyes) {
              eyes.style.opacity = Math.min(1, Math.max(0, (blinkNow - 0.25) * 2.2));
              blink.style.opacity = 0;
            } else {
              blink.style.opacity = Math.min(1, Math.max(0, (blinkNow - 0.3) * 2));
            }
          } else if (now > nextBlink) {
            if (hasClosedEyes) {
              eyes.style.opacity = 1;
              setTimeout(() => { eyes.style.opacity = 0; }, 110);
            } else {
              blink.style.opacity = 1;
              setTimeout(() => { blink.style.opacity = 0; }, 110);
            }
            nextBlink = now + 2200 + Math.random() * 4000;
          }
          requestAnimationFrame(frame);
        }

        poll();
        pollTracking();
        requestAnimationFrame(frame);
        </script>
        </body>
        </html>
        """
    }
}
