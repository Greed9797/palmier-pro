import Foundation

/// JavaScript used to drive a HyperFrames composition deterministically.
/// A scene must define `window.__hf = { duration: Number, seek(t) {...} }`.
enum HyperFramesJS {
    /// Bool: scene is loaded, seekable, fonts ready, all images decoded.
    static let readinessExpr = """
    (function(){
      try {
        if (!(window.__hf && typeof window.__hf.seek === 'function')) return false;
        var d = (typeof window.__hf.duration === 'number') ? window.__hf.duration : 0;
        if (!(d > 0)) return false;
        if (document.fonts && document.fonts.status !== 'loaded') return false;
        var imgs = Array.prototype.slice.call(document.images || []);
        if (imgs.some(function(i){ return !i.complete; })) return false;
        return true;
      } catch(e) { return false; }
    })()
    """

    /// Number: the composition duration in seconds (0 if unknown).
    static let durationExpr = """
    (function(){
      try { return (window.__hf && typeof window.__hf.duration === 'number') ? window.__hf.duration : 0; }
      catch(e) { return 0; }
    })()
    """

    /// Async body for `callAsyncJavaScript` — args: `t` (seconds), `fps`.
    /// Quantizes to the frame grid, pauses GSAP + WAAPI, seeks, and resolves
    /// only after two `requestAnimationFrame`s so the compositor has painted.
    static let seekBody = """
    const qt = Math.floor(t * fps + 1e-9) / fps;
    try {
      if (window.gsap) {
        if (gsap.ticker && gsap.ticker.sleep) gsap.ticker.sleep();
        gsap.globalTimeline.pause();
      }
    } catch(e) {}
    try { if (window.__hf && typeof window.__hf.seek === 'function') window.__hf.seek(qt); } catch(e) {}
    try {
      (document.getAnimations ? document.getAnimations() : []).forEach(function(a){
        try { a.pause(); a.currentTime = qt * 1000; } catch(e) {}
      });
    } catch(e) {}
    await new Promise(function(r){ requestAnimationFrame(function(){ requestAnimationFrame(r); }); });
    return true;
    """
}
