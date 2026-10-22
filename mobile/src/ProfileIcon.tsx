import React from 'react';
import type { AgentProfile } from './types';
import { ProjectIcon } from './ProjectIcon';

export function ProfileIcon({ profile, imageData, size = 20 }: {
  profile: AgentProfile; imageData?: string; size?: number;
}) {
  return <ProjectIcon size={size} mark={{
    name: profile.name,
    symbol: profile.iconSymbol || 'person.crop.circle',
    color: profile.iconColor || undefined,
    imageData,
  }} />;
}
