import * as DocumentPicker from 'expo-document-picker';
import { File } from 'expo-file-system';
import { uuid } from './secure';

export type PickedAttachment = {
  id: string;
  kind: 'file' | 'image' | 'githubIssue' | 'pullRequest';
  title: string;
  path: string | null;
  reference: string | null;
  url: string | null;
  body: string | null;
  details: string[];
  data: string;
  size: number;
};

const maxUploadBytes = 8 << 20;

export async function pickAttachments(existing: PickedAttachment[]): Promise<PickedAttachment[]> {
  const result = await DocumentPicker.getDocumentAsync({ multiple: true, copyToCacheDirectory: true });
  if (result.canceled) return existing;
  const added: PickedAttachment[] = [];
  let total = existing.reduce((sum, item) => sum + item.size, 0);
  for (const asset of result.assets) {
    const file = new File(asset.uri);
    const size = asset.size ?? file.size;
    total += size;
    if (total > maxUploadBytes) throw Error('Attachments must total less than 8 MB for one message.');
    const name = asset.name || file.name || 'attachment';
    added.push({ id: uuid(), kind: /\.(png|jpe?g|gif|webp)$/i.test(name) ? 'image' : 'file',
      title: name, path: null, reference: null, url: null, body: null, details: [],
      data: await file.base64(), size });
  }
  return [...existing, ...added];
}

export function attachmentPayload(items: PickedAttachment[]) {
  const attachments = items.map(({ data, size, ...attachment }) => attachment);
  const files = Object.fromEntries(items.filter(item => item.data).map(item => [item.id, item.data]));
  return { attachments, files };
}
