// Minimal i18n: message catalogs (en/fr) + Intl.PluralRules. The production app would use ICU
// MessageFormat (e.g. FormatJS) with the same catalog keys, shared with the Rust side (fluent).
type Msg = string | { one: string; other: string };
const catalogs: Record<string, Record<string, Msg>> = {
  en: {
    "project.untitled": "Untitled project",
    "action.export": "Export", "action.play": "Play", "action.pause": "Pause",
    "action.split": "Split", "action.delete": "Delete",
    "tab.media": "Media", "tab.audio": "Audio", "tab.text": "Text", "tab.effects": "Effects",
    "tab.transitions": "Transitions", "tab.filters": "Filters",
    "inspector.title": "Video", "inspector.opacity": "Opacity", "inspector.saturation": "Saturation",
    "inspector.brightness": "Brightness",
    "timeline.clips": { one: "{n} clip on {t} tracks", other: "{n} clips on {t} tracks" },
    "clip.label": "Clip {n}",
    "player.seek": "Seek: {ms} ms",
  },
  fr: {
    "project.untitled": "Projet sans titre",
    "action.export": "Exporter", "action.play": "Lecture", "action.pause": "Pause",
    "action.split": "Diviser", "action.delete": "Supprimer",
    "tab.media": "Médias", "tab.audio": "Audio", "tab.text": "Texte", "tab.effects": "Effets",
    "tab.transitions": "Transitions", "tab.filters": "Filtres",
    "inspector.title": "Vidéo", "inspector.opacity": "Opacité", "inspector.saturation": "Saturation",
    "inspector.brightness": "Luminosité",
    "timeline.clips": { one: "{n} clip sur {t} pistes", other: "{n} clips sur {t} pistes" },
    "clip.label": "Clip {n}",
    "player.seek": "Recherche : {ms} ms",
  },
};
let lang = "en";
export function setLang(l: string) { lang = l.startsWith("fr") ? "fr" : "en"; document.documentElement.lang = lang; apply(); }
export function getLang() { return lang; }
export function t(key: string, vars: Record<string, string | number> = {}): string {
  let m = catalogs[lang][key] ?? catalogs.en[key] ?? key;
  if (typeof m !== "string") {
    const cat = new Intl.PluralRules(lang).select(Number(vars.n ?? 0));
    m = cat === "one" ? m.one : m.other;
  }
  return m.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? ""));
}
export function apply() {
  document.querySelectorAll<HTMLElement>("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n!); });
}
