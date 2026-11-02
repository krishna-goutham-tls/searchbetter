import React from "react";
import { Composition } from "remotion";
import { Teaser } from "./Teaser";
import t from "./timeline.json";
export const Root: React.FC = () => (
  <Composition id="Teaser" component={Teaser} width={1660} height={1080} fps={30} durationInFrames={Math.round(t.total * 30)} />
);
