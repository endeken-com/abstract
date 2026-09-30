import React from 'react';
import { SvgXml } from 'react-native-svg';
import { SymbolView } from 'expo-symbols';
import theme from './material-icons.json';

// The same Material Icon Theme manifest used by Abstract/Components/FileIcon.swift.
// Upstream theme: https://github.com/material-extensions/vscode-material-icon-theme (MIT).
export function FileIcon({ path, directory = false, open = false, size = 16 }: { path: string; directory?: boolean; open?: boolean; size?: number }) {
  const name = path.split('/').filter(Boolean).at(-1)?.toLowerCase() || '';
  let iconName: string | undefined;
  if (directory) {
    const base = (theme.folderNames as Record<string, string>)[name] || 'folder';
    iconName = open && (theme.icons as Record<string, string>)[`${base}-open`] ? `${base}-open` : base;
  } else {
    iconName = (theme.fileNames as Record<string, string>)[name];
    if (!iconName) {
      const parts = name.split('.');
      for (let index = 1; index < parts.length; index++) {
        iconName = (theme.fileExtensions as Record<string, string>)[parts.slice(index).join('.')];
        if (iconName) break;
      }
    }
  }
  const xml = iconName && (theme.icons as Record<string, string>)[iconName];
  return xml
    ? <SvgXml xml={xml} width={size} height={size} />
    : <SymbolView name={{ ios: directory ? 'folder' : 'doc', android: directory ? 'folder' : 'description', web: directory ? 'folder' : 'description' }} size={size} tintColor="#75757E" style={{ width: size, height: size }} />;
}
