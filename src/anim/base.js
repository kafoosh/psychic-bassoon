// Shared fields of every routine (the Swift structs all copy the same RoutineSetup values).

import { inkColor, inkWidth } from '../rig/model.js';

export class RoutineBase {
  constructor(s) {
    this.rig = s.rig;
    this.dropDistance = s.dropDistance;
    this.walkDX = s.walkDX;
    this.sideSign = s.sideSign;
    this.propScale = s.propScale;
    this.screenSize = s.screenSize;
    this.topInset = s.topInset;
    this.bottomInset = s.bottomInset;
    this.skel = s.rig.skeleton;
    this.ink = inkColor(s.rig);
    this.lw = Math.max(inkWidth(s.rig) * 0.9, 3);
  }
  get fitMargins() { return { topMargin: this.topInset, bottomMargin: this.bottomInset }; }
}
