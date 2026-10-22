import i18n from "i18next";
import english from "./locales/en.json";
import portuguese from "./locales/pt_br.json";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";

const languages = [
  ["az", "Azərbaycan"],
  ["en", "English"],
  ["el", "Ελληνικά"],
  ["am", "Հայերեն"],
  ["es", "Español"],
  ["it", "Italiano"],
  ["de", "Deutsch"],
  ["de_ch", "Schweizerdeutsch"],
  ["fr", "Français"],
  ["pl", "Polski"],
  ["nl", "Nederlands"],
  ["vi", "Tiếng Việt"],
  ["ru", "Русский"],
  ["uk", "Українська"],
  ["ro", "Română"],
  ["ar", "العربية"],
  ["tr", "Türkçe"],
  ["zh_tw", "Traditional Chinese （繁體中文)"],
  ["zh_cn", "Simplified Chinese （简体中文)"],
  ["ko", "한국어"],
  ["zh_hk", "Cantonese （粵語)"],
  ["ja", "日本語"],
  ["cs_cz", "Čeština"],
  ["sv", "Svenska"],
  ["hu", "Magyar"],
  ["kh", "ភាសាខ្មែរ"],
  ["id", "Bahasa Indonesia"],
  ["pt_br", "Português (Brasileiro)"]
] as const;

export const sortedLanguages = [...languages].sort((a, b) =>
  a[0].localeCompare(b[0]),
);

const resources = {
  en: { translation: english },
  pt_br: { translation: portuguese },
};

i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    lng: "pt_br",
    fallbackLng: "en",
    interpolation: {
      escapeValue: false,
    },
    resources,
  });

export default i18n;
