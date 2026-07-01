/* Aperture · Haptic vocabulary
   Haptics treated as a design material: every meaningful moment has a named pattern.
   Each pattern carries: a web Vibration API timing array (best-effort, Android/Chrome),
   the iOS UIKit / Core Haptics equivalent, the Android constant, and a waveform shape
   for the visual. iOS Safari ignores navigator.vibrate — the spec is the source of truth.
   API: HAPTICS[name] = {label, web:[...], ios, android, intensity, curve, desc, group} */
(function(){
  const H={
    /* — Discrete feedback — */
    tap:        {label:'Tap',           group:'Feedback', web:[8],            ios:'UIImpactFeedbackGenerator(.light)',  android:'HapticFeedbackConstants.KEYBOARD_TAP', intensity:0.25, curve:[[0,0],[0.1,1],[0.3,0]], desc:'A light tick under primary buttons & key presses.'},
    select:     {label:'Selection',     group:'Feedback', web:[5],            ios:'UISelectionFeedbackGenerator.selectionChanged()', android:'HapticFeedbackConstants.CLOCK_TICK', intensity:0.18, curve:[[0,0],[0.08,0.8],[0.2,0]], desc:'Crisp detent as a value changes — pickers, segmented controls, amount steppers.'},
    toggle:     {label:'Toggle',        group:'Feedback', web:[12],           ios:'UIImpactFeedbackGenerator(.rigid)',  android:'HapticFeedbackConstants.CONTEXT_CLICK', intensity:0.4, curve:[[0,0],[0.12,1],[0.32,0]], desc:'A firmer click for switches and on/off state.'},
    /* — Impact (weight) — */
    impactLight:{label:'Impact · Light',group:'Impact', web:[10],            ios:'UIImpactFeedbackGenerator(.light)',  android:'VibrationEffect.Composition · LOW_TICK', intensity:0.3, curve:[[0,0],[0.12,0.7],[0.3,0]], desc:'Lightweight collision — sheet snaps to a detent.'},
    impactMedium:{label:'Impact · Medium',group:'Impact',web:[18],           ios:'UIImpactFeedbackGenerator(.medium)', android:'VibrationEffect.Composition · CLICK', intensity:0.55, curve:[[0,0],[0.14,0.9],[0.34,0]], desc:'The default landing — the logo settling, a card committing.'},
    impactHeavy:{label:'Impact · Heavy',group:'Impact', web:[28],            ios:'UIImpactFeedbackGenerator(.heavy)',  android:'VibrationEffect.Composition · HEAVY_CLICK', intensity:0.85, curve:[[0,0],[0.16,1],[0.4,0]], desc:'A weighty thud for big, deliberate confirmations.'},
    /* — Notifications (outcome) — */
    success:    {label:'Success',       group:'Outcome', web:[14,60,22],     ios:'UINotificationFeedbackGenerator.success', android:'VibrationEffect.Composition · CLICK + tick', intensity:0.6, curve:[[0,0],[0.1,0.9],[0.25,0.1],[0.55,0],[0.62,0.7],[0.8,0]], desc:'Two-beat lift on a confirmed transaction, swap, or refresh.'},
    warning:    {label:'Warning',       group:'Outcome', web:[20,50,20],     ios:'UINotificationFeedbackGenerator.warning', android:'VibrationEffect.Composition · DOUBLE_CLICK', intensity:0.65, curve:[[0,0],[0.12,0.85],[0.3,0],[0.45,0.85],[0.62,0]], desc:'Even double-pulse — “read this before you continue.”'},
    error:      {label:'Error',         group:'Outcome', web:[40,30,40,30,40],ios:'UINotificationFeedbackGenerator.error', android:'VibrationEffect · waveform buzz', intensity:0.9, curve:[[0,0],[0.08,0.9],[0.18,0.2],[0.3,0.95],[0.42,0.2],[0.55,0.95],[0.7,0]], desc:'Three-beat rumble for a failed or rejected action.'},
    /* — Signature (brand) — */
    irisSettle: {label:'Iris Settle',   group:'Signature', web:[6,20,16],    ios:'CHHapticPattern · light→medium transient', android:'Composition · LOW_TICK → CLICK', intensity:0.5, curve:[[0,0],[0.1,0.5],[0.22,0.05],[0.4,0],[0.5,1],[0.72,0]], desc:'The brand moment: a soft tick as the aperture opens, then a medium tap as it locks. Used on splash→home and pull-to-refresh completion.'},
    sendWhoosh: {label:'Send Off',      group:'Signature', web:[8,18,14,18,26],ios:'CHHapticPattern · rising continuous + transient', android:'Composition rising ramp', intensity:0.7, curve:[[0,0],[0.15,0.3],[0.35,0.5],[0.55,0.7],[0.8,1],[0.95,0]], desc:'A rising ramp that resolves into a pop — the instant funds leave on a swipe-to-send.'},
    countUp:    {label:'Balance Tick',  group:'Signature', web:[4],          ios:'UIImpactFeedbackGenerator(.soft) · per digit', android:'CLOCK_TICK · per digit', intensity:0.15, curve:[[0,0],[0.1,0.6],[0.25,0]], desc:'A whisper-soft tick per rolling digit as a balance counts up. Subtle, never spammy.'},
  };
  // build a Vibration-API sequence (gaps already encoded as [on,off,on,...])
  function play(name){
    const p=H[name]; if(!p) return false;
    if(navigator.vibrate){ try{ navigator.vibrate(0); navigator.vibrate(p.web); return true; }catch(e){} }
    return false;
  }
  window.HAPTICS=H;
  window.HAPTICS_play=play;
  window.HAPTICS_KEYS=Object.keys(H);
})();
