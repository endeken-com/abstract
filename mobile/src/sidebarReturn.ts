import type { MacView } from './macs';

// A screen in the phone's stack, as navigation state keeps it.
export type StackRoute = { name: string; params?: Record<string, unknown> };
// Where closing the sidebar goes back to: the screens that were above it.
export type SidebarReturn = StackRoute[] | null;

const chatOf = (route: StackRoute) => {
  const hostId = route.params?.hostId, sessionId = route.params?.sessionId;
  return typeof hostId === 'string' && typeof sessionId === 'string' ? { hostId, sessionId } : null;
};

// The stack fell back to the sidebar: remember what it left when that was a
// chat (with anything opened from it), so Close returns there. Leaving a
// screen opened from the sidebar itself, like Settings, keeps the chat that
// was remembered before. Any other change keeps it too.
export function nextSidebarReturn(previous: StackRoute[], next: StackRoute[], remembered: SidebarReturn): SidebarReturn {
  if (next.length !== 1 || next[0].name !== 'Sidebar' || previous.length < 2) return remembered;
  const left = previous.slice(1).map(({ name, params }) => ({ name, params }));
  return left.some(route => route.name === 'Chat') ? left : remembered;
}

// The remembered chat, while every chat its screens belong to still exists.
// A Mac that hasn't sent a snapshot yet can't say, so its chats are kept.
export function restorable(remembered: SidebarReturn, macs: MacView[]): SidebarReturn {
  if (!remembered?.length) return null;
  const exists = remembered.every(route => {
    const chat = chatOf(route);
    if (!chat) return true;
    const mac = macs.find(x => x.id === chat.hostId);
    return !!mac && (!mac.snapshot || mac.snapshot.sessions.some(x => x.id === chat.sessionId));
  });
  return exists ? remembered : null;
}

// The chat Close returns to, to mark it in the list.
export function returnChat(remembered: SidebarReturn) {
  const route = remembered?.filter(x => x.name === 'Chat').at(-1);
  return route ? chatOf(route) : null;
}
