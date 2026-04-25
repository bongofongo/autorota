use fluent::FluentResource;
use fluent::concurrent::FluentBundle;
use std::sync::OnceLock;
use unic_langid::{LanguageIdentifier, langid};

const EN_FTL: &str = include_str!("../i18n/en/errors.ftl");
const ZH_HANS_FTL: &str = include_str!("../i18n/zh-Hans/errors.ftl");
const ZH_HANT_FTL: &str = include_str!("../i18n/zh-Hant/errors.ftl");
const AR_FTL: &str = include_str!("../i18n/ar/errors.ftl");
const BN_FTL: &str = include_str!("../i18n/bn/errors.ftl");
const HI_FTL: &str = include_str!("../i18n/hi/errors.ftl");
const ES_FTL: &str = include_str!("../i18n/es/errors.ftl");

struct Bundles {
    en: FluentBundle<FluentResource>,
    zh_hans: FluentBundle<FluentResource>,
    zh_hant: FluentBundle<FluentResource>,
    ar: FluentBundle<FluentResource>,
    bn: FluentBundle<FluentResource>,
    hi: FluentBundle<FluentResource>,
    es: FluentBundle<FluentResource>,
}

static BUNDLES: OnceLock<Bundles> = OnceLock::new();

fn build_bundle(lang: LanguageIdentifier, src: &str) -> FluentBundle<FluentResource> {
    let mut bundle = FluentBundle::new_concurrent(vec![lang]);
    bundle.set_use_isolating(false);
    if let Ok(res) = FluentResource::try_new(src.to_string()) {
        let _ = bundle.add_resource(res);
    }
    bundle
}

fn bundles() -> &'static Bundles {
    BUNDLES.get_or_init(|| Bundles {
        en: build_bundle(langid!("en"), EN_FTL),
        zh_hans: build_bundle(langid!("zh-Hans"), ZH_HANS_FTL),
        zh_hant: build_bundle(langid!("zh-Hant"), ZH_HANT_FTL),
        ar: build_bundle(langid!("ar"), AR_FTL),
        bn: build_bundle(langid!("bn"), BN_FTL),
        hi: build_bundle(langid!("hi"), HI_FTL),
        es: build_bundle(langid!("es"), ES_FTL),
    })
}

fn pick_bundle(locale: &str) -> &'static FluentBundle<FluentResource> {
    let b = bundles();
    let lang: LanguageIdentifier = locale.parse().unwrap_or_else(|_| langid!("en"));
    let script = lang.script.map(|s| s.as_str().to_string());
    match (lang.language.as_str(), script.as_deref()) {
        ("zh", Some("Hant")) => &b.zh_hant,
        ("zh", _) => &b.zh_hans,
        ("ar", _) => &b.ar,
        ("bn", _) => &b.bn,
        ("hi", _) => &b.hi,
        ("es", _) => &b.es,
        _ => &b.en,
    }
}

fn format_message(bundle: &FluentBundle<FluentResource>, msg_id: &str) -> Option<String> {
    let msg = bundle.get_message(msg_id)?;
    let pattern = msg.value()?;
    let mut errs = vec![];
    Some(bundle.format_pattern(pattern, None, &mut errs).into_owned())
}

/// Look up `msg_id` in the bundle for `locale`, falling back to English when
/// the requested locale lacks the key (or doesn't parse).
pub fn localize(msg_id: &str, locale: &str) -> String {
    let bundle = pick_bundle(locale);
    if let Some(s) = format_message(bundle, msg_id) {
        return s;
    }
    if let Some(s) = format_message(&bundles().en, msg_id) {
        return s;
    }
    format!("[{msg_id}]")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn english_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "en"),
            "Employee not found."
        );
    }

    #[test]
    fn missing_msg_id_falls_back_to_english() {
        // bn is populated, but unknown keys should still fall back to English.
        assert_eq!(
            localize("err-does-not-exist-in-bn", "bn"),
            "[err-does-not-exist-in-bn]"
        );
    }

    #[test]
    fn unknown_locale_falls_back_to_english() {
        assert_eq!(
            localize("err-invalid-date", "fr-FR"),
            "The date format is invalid."
        );
    }

    #[test]
    fn malformed_locale_falls_back_to_english() {
        assert_eq!(
            localize("err-invalid-generic", "garbage!!"),
            "The provided value is invalid."
        );
    }

    #[test]
    fn unknown_msg_id_returns_bracketed_key() {
        assert_eq!(localize("err-does-not-exist", "en"), "[err-does-not-exist]");
    }

    #[test]
    fn traditional_chinese_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "zh-Hant"),
            "找不到員工。"
        );
    }

    #[test]
    fn simplified_chinese_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "zh-Hans"),
            "找不到员工。"
        );
    }

    #[test]
    fn arabic_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "ar"),
            "لم يتم العثور على الموظف."
        );
    }

    #[test]
    fn bengali_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "bn"),
            "কর্মচারী খুঁজে পাওয়া যায়নি।"
        );
    }

    #[test]
    fn hindi_lookup_works() {
        assert_eq!(localize("err-not-found-employee", "hi"), "कर्मचारी नहीं मिला।");
    }

    #[test]
    fn spanish_lookup_works() {
        assert_eq!(
            localize("err-not-found-employee", "es"),
            "No se encontró el empleado."
        );
    }
}
