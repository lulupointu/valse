// Minimal i18n: message catalogs + Intl.PluralRules (ICU-style plurals). Production would use i18next/FormatJS
// with the same catalog shape. Language follows navigator.language (system), overridable.
const en = {
  'app.title': 'Montage', 'player.label': 'Player', 'timeline.label': 'Timeline', 'inspector.title': 'Details',
  'inspector.empty': 'Select a clip to edit its properties', 'toolbar.split': 'Split', 'toolbar.undo': 'Undo', 'toolbar.redo': 'Redo',
  'toolbar.export': 'Export', 'media.title': 'Media', 'bench.running': 'Benchmark: {name}',
  'track.video': 'Video', 'track.audio': 'Audio', 'track.text': 'Text', 'track.effect': 'Effects',
  'clips.count': { one: '{n} clip', other: '{n} clips' },
} as const;
type Key = keyof typeof en;
const fr: Record<Key, string | { one: string; other: string }> = {
  'app.title': 'Montage', 'player.label': 'Lecteur', 'timeline.label': 'Timeline', 'inspector.title': 'Détails',
  'inspector.empty': 'Sélectionnez un clip pour modifier ses propriétés', 'toolbar.split': 'Diviser', 'toolbar.undo': 'Annuler', 'toolbar.redo': 'Rétablir',
  'toolbar.export': 'Exporter', 'media.title': 'Médias', 'bench.running': 'Banc d’essai : {name}',
  'track.video': 'Vidéo', 'track.audio': 'Audio', 'track.text': 'Texte', 'track.effect': 'Effets',
  'clips.count': { one: '{n} clip', other: '{n} clips' },
};
let lang: 'en' | 'fr' = navigator.language.startsWith('fr') ? 'fr' : 'en';
export const setLang = (l: 'en' | 'fr') => { lang = l; };
export function t(key: string, vars: Record<string, string | number> = {}): string {
  const cat = (lang === 'fr' ? fr : en) as Record<string, string | { one: string; other: string }>;
  let m = cat[key] ?? (en as Record<string, unknown>)[key] ?? key;
  if (typeof m === 'object') m = m[new Intl.PluralRules(lang).select(Number(vars.n ?? 0)) as 'one' | 'other'] ?? m.other;
  return (m as string).replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? ''));
}
