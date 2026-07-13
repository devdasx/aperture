#!/usr/bin/env python3
"""Generate fixes.jsonl + report.json for agent01 languages: af, ar, bg, bn, ca."""
from __future__ import annotations

import json
from pathlib import Path

DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# SKIP: language-neutral, brand/tech proper nouns, format-only, dev strings.
# These are flagged as untranslated but should remain as-is.
# ---------------------------------------------------------------------------
SKIP_KEYS = {
    "%lld",
    "%@ SOL",
    "%lld, %@",
    "\\(percent)%",
    "\\(currency.symbol) · \\(currency.code)",
    "\\(row.name) · \\(row.chain.displayName)",
    "\\(row.symbol) — \\(row.name)",
    "\\(row.symbol) · \\(row.chain.displayName)",
    "aperture-custom-tokens.csv",
    "Coinbase",
    "xpub / ypub / zpub",
    "SF Symbols",
    "Trust Wallet Assets",
    "Nonce",  # industry term kept Latin
    "Hash",  # crypto term
    "Replace-By-Fee",  # Bitcoin protocol name
    "OP_RETURN",
    "ENS",
    "UTF-8",
    "Use ConcentricRectangle() inside a .containerShape(.rect(cornerRadius:)) parent instead.",
    "Perps",  # industry shorthand; partial localizations already ok
    # Inflection templates — keep structure; "token" often stays for crypto
    "^[%@ token](inflect: true)",
    "^[%lld token](inflect: true)",
    "^[\\(tokenCount) token](inflect: true)",
}

# Translations: key -> {lang: new_value}
# Only include langs that currently need a fix (old == en or missing).
T: dict[str, dict[str, str]] = {}


def t(key: str, **langs: str) -> None:
    T[key] = langs


# === Short UI / labels ===
t(
    "Account",
    af="Rekening",
    bg="Акаунт",
    bn="অ্যাকাউন্ট",
    ca="Compte",
)
t("Filter", af="Filter")
t("Letter", af="Letter")
t("Status", af="Status")
t("Minimum", af="Minimum")
t("Enable %@", af="Aktiveer %@")
t("Use %@", af="Gebruik %@")
t("Status: %@", af="Status: %@")
t("Biometrics", af="Biometrie")
t(
    "Index",
    af="Indeks",
    bg="Индекс",
    bn="ইনডেক্স",
    ca="Índex",
)
t(
    "Paths",
    af="Paaie",
    bg="Пътища",
    bn="পাথ",
    ca="Rutes",
)
t(
    "Branch",
    af="Tak",
    bg="Клон",
    bn="শাখা",
    ca="Branca",
)
t(
    "Text",
    af="Teks",
    bg="Текст",
    bn="টেক্সট",
    ca="Text",
)
t(
    "Tint",
    af="Tint",
    ca="Tint",
)
t(
    "Tokens",
    af="Tokens",
    ca="Tokens",
)
t(
    "Memo",
    af="Memo",
    ca="Memo",
)
t("Mode", ca="Mode")
t("Color", ca="Color")
t("Error", ca="Error")
t("Total", ca="Total")
t("Normal", ca="Normal")
t("Social", ca="Social")
t("Visible", ca="Visibles")
t("Decimals", ca="Decimals")
t("Self", af="Jouself")
t("Swap", bg="Размяна")
t("Payload", bg="Полезен товар")
t("Token mint", bg="Токен-минт")
t(
    "Locktime",
    bg="Време на заключване",
    bn="লকটাইম",
)
t(
    "Losers",
    af="Dalers",
    bg="Губещи",
    bn="পতনশীল",
    ca="Perdedors",
)
t(
    "Gainers",
    af="Stygers",
    bg="Печеливши",
    bn="উর্ধ্বগামী",
    ca="Guanyadors",
)
t(
    "Watchlist",
    af="Dophoulys",
    bg="Списък за наблюдение",
    bn="ওয়াচলিস্ট",
    ca="Llista de seguiment",
)
t(
    "Circulating",
    af="In omloop",
    bg="В обращение",
    bn="প্রচলিত",
    ca="En circulació",
)
t(
    "Market cap",
    af="Markkapitalisasie",
    bg="Пазарна капитализация",
    bn="মার্কেট ক্যাপ",
    ca="Capitalització de mercat",
)
t(
    "24h high",
    af="24u hoog",
    bg="24ч макс.",
    bn="২৪ঘ সর্বোচ্চ",
    ca="Màxim 24 h",
)
t(
    "24h low",
    af="24u laag",
    bg="24ч мин.",
    bn="২৪ঘ সর্বনিম্ন",
    ca="Mínim 24 h",
)
t(
    "24h volume",
    af="24u volume",
    bg="24ч обем",
    bn="২৪ঘ ভলিউম",
    ca="Volum 24 h",
)
t(
    "24h PnL",
    af="24u PnL",
    bg="24ч PnL",
    ca="PnL 24 h",
)
t(
    "Stablecoins",
    af="Stablecoins",
    ca="Stablecoins",
)
t(
    "Send %@",
    af="Stuur %@",
    bg="Изпрати %@",
    bn="%@ পাঠান",
    ca="Envia %@",
)
t(
    "URL: %@",
    af="URL: %@",
    bg="URL: %@",
    bn="URL: %@",
    ca="URL: %@",
)
t(
    "%lld tx",
    af="%lld tx",
    bg="%lld tx",
    bn="%lld লেনদেন",
    ca="%lld tx",
)

# Missing accessibility strings (positional placeholders match English catalog)
t(
    "%@, %@ %@",
    af="%1$@, %2$@ %3$@",
    ar="%1$@، %2$@ %3$@",
    bg="%1$@, %2$@ %3$@",
    bn="%1$@, %2$@ %3$@",
    ca="%1$@, %2$@ %3$@",
)
t(
    "%@, selected for send, %@ %@",
    af="%1$@, gekies om te stuur, %2$@ %3$@",
    ar="%1$@، محدد للإرسال، %2$@ %3$@",
    bg="%1$@, избрано за изпращане, %2$@ %3$@",
    bn="%1$@, পাঠানোর জন্য নির্বাচিত, %2$@ %3$@",
    ca="%1$@, seleccionat per enviar, %2$@ %3$@",
)

# Speed / fee labels
t(
    "~ faster",
    af="~ vinniger",
    bg="~ по-бързо",
    bn="~ দ্রুততর",
    ca="~ més ràpid",
)
t(
    "~ slower",
    af="~ stadiger",
    bg="~ по-бавно",
    bn="~ ধীরতর",
    ca="~ més lent",
)
t(
    "~ normal",
    af="~ normaal",
    bg="~ нормално",
    bn="~ স্বাভাবিক",
    ca="~ normal",
)
t(
    "~ a few s",
    af="~ 'n paar s",
    bg="~ няколко s",
    bn="~ কয়েক সেকেন্ড",
    ca="~ uns quants s",
)
t(
    "~1–2 min",
    af="~1–2 min",
    bg="~1–2 мин",
    bn="~১–২ মিনিট",
    ca="~1–2 min",
)
t(
    "~1–3 min",
    af="~1–3 min",
    bg="~1–3 мин",
    bn="~১–৩ মিনিট",
    ca="~1–3 min",
)
t(
    "~5–15 min",
    af="~5–15 min",
    bg="~5–15 мин",
    bn="~৫–১৫ মিনিট",
    ca="~5–15 min",
)
t(
    "~10–30 min",
    af="~10–30 min",
    bg="~10–30 мин",
    bn="~১০–৩০ মিনিট",
    ca="~10–30 min",
)
t(
    "~30–60 min",
    af="~30–60 min",
    ca="~30–60 min",
)
t(
    "~30+ min",
    af="~30+ min",
    ca="~30+ min",
)
t(
    "~ next block (~3 s)",
    af="~ volgende blok (~3 s)",
    bg="~ следващ блок (~3 s)",
    bn="~ পরবর্তী ব্লক (~৩ সে)",
    ca="~ bloc següent (~3 s)",
)
t(
    "~ next block (~6 s)",
    af="~ volgende blok (~6 s)",
    bg="~ следващ блок (~6 s)",
    bn="~ পরবর্তী ব্লক (~৬ সে)",
    ca="~ bloc següent (~6 s)",
)
t(
    "~ next block (~12 s)",
    af="~ volgende blok (~12 s)",
    bg="~ следващ блок (~12 s)",
    bn="~ পরবর্তী ব্লক (~১২ সে)",
    ca="~ bloc següent (~12 s)",
)
t(
    "~ next block (~10 min)",
    af="~ volgende blok (~10 min)",
    bg="~ следващ блок (~10 мин)",
    bn="~ পরবর্তী ব্লক (~১০ মিনিট)",
    ca="~ bloc següent (~10 min)",
)
t(
    "~ next ledger (~5 s)",
    af="~ volgende ledger (~5 s)",
    bg="~ следващ ledger (~5 s)",
    bn="~ পরবর্তী লেজার (~৫ সে)",
    ca="~ ledger següent (~5 s)",
)
t(
    "~ next ledger (~3–5 s)",
    af="~ volgende ledger (~3–5 s)",
    bg="~ следващ ledger (~3–5 s)",
    bn="~ পরবর্তী লেজার (~৩–৫ সে)",
    ca="~ ledger següent (~3–5 s)",
)
t(
    "~ next slot (~0.4 s)",
    af="~ volgende slot (~0.4 s)",
    bg="~ следващ слот (~0,4 s)",
    bn="~ পরবর্তী স্লট (~০.৪ সে)",
    ca="~ slot següent (~0,4 s)",
)

# Wallet / security
t(
    "Unlock Aperture",
    af="Ontsluit Aperture",
    bg="Отключи Aperture",
    bn="Aperture আনলক করুন",
    ca="Desbloqueja Aperture",
)
t(
    "Turn Off Passcode",
    af="Skakel toegangskode af",
    bg="Изключи кода за достъп",
    bn="পাসকোড বন্ধ করুন",
    ca="Desactiva el codi d’accés",
)
t(
    "Remove Wallet",
    af="Verwyder beursie",
    bg="Премахни портфейла",
    bn="ওয়ালেট সরান",
    ca="Elimina la cartera",
)
t(
    "View Wallet Secrets",
    af="Bekyk beursiegeheime",
    bg="Виж тайните на портфейла",
    bn="ওয়ালেট সিক্রেট দেখুন",
    ca="Mostra els secrets de la cartera",
)
t(
    "Access Security Settings",
    af="Maak sekuriteitinstellings oop",
    bg="Отвори настройките за сигурност",
    bn="নিরাপত্তা সেটিংস খুলুন",
    ca="Obre els ajustaments de seguretat",
)
t(
    "Sign %@ Transaction",
    af="Teken %@-transaksie",
    bg="Подпиши транзакция %@",
    bn="%@ লেনদেন সাইন করুন",
    ca="Signa la transacció %@",
)
t(
    "Failed · Aperture",
    af="Misluk · Aperture",
    bg="Неуспешно · Aperture",
    bn="ব্যর্থ · Aperture",
    ca="Ha fallat · Aperture",
)
t(
    "Confirming · Aperture",
    af="Bevestig tans · Aperture",
    bg="Потвърждаване · Aperture",
    bn="নিশ্চিত হচ্ছে · Aperture",
    ca="S’està confirmant · Aperture",
)

# CSV / wallet ops
t(
    "Couldn't export CSV",
    af="Kon nie CSV uitvoer nie",
    bg="CSV не можа да се експортира",
    bn="CSV রপ্তানি করা যায়নি",
    ca="No s’ha pogut exportar el CSV",
)
t(
    "Couldn't import CSV",
    af="Kon nie CSV invoer nie",
    bg="CSV не можа да се импортира",
    bn="CSV আমদানি করা যায়নি",
    ca="No s’ha pogut importar el CSV",
)
t(
    "Couldn't remove wallet",
    af="Kon nie beursie verwyder nie",
    bg="Портфейлът не можа да се премахне",
    bn="ওয়ালেট সরানো যায়নি",
    ca="No s’ha pogut eliminar la cartera",
)
t(
    "Couldn't rename wallet",
    af="Kon nie beursie hernoem nie",
    bg="Портфейлът не можа да се преименува",
    bn="ওয়ালেটের নাম পরিবর্তন করা যায়নি",
    ca="No s’ha pogut canviar el nom de la cartera",
)

# Scan / derivation
t(
    "Build results",
    af="Bou resultate",
    bg="Резултати от изграждане",
    bn="বিল্ড ফলাফল",
    ca="Resultats de la construcció",
)
t(
    "Derive local addresses",
    af="Lei plaaslike adresse af",
    bg="Изведи локални адреси",
    bn="লোকাল ঠিকানা ডেরাইভ করুন",
    ca="Deriva adreces locals",
)
t(
    "Local addresses ready",
    af="Plaaslike adresse gereed",
    bg="Локалните адреси са готови",
    bn="লোকাল ঠিকানা প্রস্তুত",
    ca="Adreces locals a punt",
)
t(
    "Parallel Solana scan",
    af="Parallelle Solana-skandering",
    bg="Паралелно сканиране на Solana",
    bn="সমান্তরাল Solana স্ক্যান",
    ca="Escaneig paral·lel de Solana",
)
t(
    "Parallel network scan",
    af="Parallelle netwerkskandering",
    bg="Паралелно мрежово сканиране",
    bn="সমান্তরাল নেটওয়ার্ক স্ক্যান",
    ca="Escaneig paral·lel de xarxa",
)
t(
    "Check balances and tokens",
    af="Kontroleer saldo's en tokens",
    bg="Провери баланси и токени",
    bn="ব্যালেন্স ও টোকেন পরীক্ষা করুন",
    ca="Comprova saldos i tokens",
)
t(
    "Check SOL and SPL tokens",
    af="Kontroleer SOL- en SPL-tokens",
    bg="Провери SOL и SPL токени",
    bn="SOL ও SPL টোকেন পরীক্ষা করুন",
    ca="Comprova tokens SOL i SPL",
)
t(
    "Funded accounts move to the top",
    af="Befondsde rekeninge skuif na bo",
    bg="Акаунтите със средства отиват най-горе",
    bn="তহবিলযুক্ত অ্যাকাউন্ট উপরে যায়",
    ca="Els comptes amb fons pugen a dalt",
)
t(
    "Funded addresses move to the top",
    af="Befondsde adresse skuif na bo",
    bg="Адресите със средства отиват най-горе",
    bn="তহবিলযুক্ত ঠিকানা উপরে যায়",
    ca="Les adreces amb fons pugen a dalt",
)
t(
    "Funded accounts move to the top when the scan completes",
    af="Befondsde rekeninge skuif na bo wanneer die skandering klaar is",
    bg="Акаунтите със средства отиват най-горе след завършване на сканирането",
    bn="স্ক্যান শেষ হলে তহবিলযুক্ত অ্যাকাউন্ট উপরে যায়",
    ca="Els comptes amb fons pugen a dalt quan acaba l’escaneig",
)
t(
    "Address index",
    af="Adresindeks",
    bg="Индекс на адреса",
    bn="ঠিকানা ইনডেক্স",
    ca="Índex d’adreça",
)
t(
    "Hardened account number",
    af="Verharde rekeningnommer",
    bg="Укрепен номер на акаунт",
    bn="হার্ডেনড অ্যাকাউন্ট নম্বর",
    ca="Número de compte hardenat",
)
t(
    "0 receive, 1 change",
    af="0 ontvang, 1 wisselgeld",
    bg="0 получаване, 1 ресто",
    bn="০ রিসিভ, ১ চেঞ্জ",
    ca="0 recepció, 1 canvi",
)
t(
    "All EVM chains",
    af="Alle EVM-kettings",
    bg="Всички EVM вериги",
    bn="সব EVM চেইন",
    ca="Totes les cadenes EVM",
)
t(
    "Stellar memo",
    af="Stellar-memo",
    bg="Stellar бележка",
    bn="Stellar মেমো",
    ca="Memo de Stellar",
)
t(
    "Destination tag (optional)",
    af="Bestemmingstiket (opsioneel)",
    bg="Destination tag (по избор)",
    bn="ডেস্টিনেশন ট্যাগ (ঐচ্ছিক)",
    ca="Etiqueta de destinació (opcional)",
)

# Address type hints
t(
    "Legacy, starts with 1.",
    af="Legacy, begin met 1.",
    bg="Legacy, започва с 1.",
    bn="Legacy, ১ দিয়ে শুরু।",
    ca="Legacy, comença per 1.",
)
t(
    "Native SegWit, starts with bc1q.",
    af="Native SegWit, begin met bc1q.",
    bg="Native SegWit, започва с bc1q.",
    bn="Native SegWit, bc1q দিয়ে শুরু।",
    ca="SegWit natiu, comença per bc1q.",
)
t(
    "Wrapped SegWit, starts with 3.",
    af="Wrapped SegWit, begin met 3.",
    bg="Wrapped SegWit, започва с 3.",
    bn="Wrapped SegWit, ৩ দিয়ে শুরু।",
    ca="SegWit embolcallat, comença per 3.",
)
t(
    "Taproot, starts with bc1p.",
    af="Taproot, begin met bc1p.",
    bg="Taproot, започва с bc1p.",
    bn="Taproot, bc1p দিয়ে শুরু।",
    ca="Taproot, comença per bc1p.",
)

# Validation / errors
t(
    "Add at least one recipient",
    af="Voeg ten minste een ontvanger by",
    bg="Добави поне един получател",
    bn="অন্তত একজন প্রাপক যোগ করুন",
    ca="Afegeix almenys un destinatari",
)
t(
    "Amount is too small to send",
    af="Bedrag is te klein om te stuur",
    bg="Сумата е твърде малка за изпращане",
    bn="পাঠানোর জন্য পরিমাণ খুব ছোট",
    ca="L’import és massa petit per enviar",
)
t(
    "Enter an amount greater than zero",
    af="Voer 'n bedrag groter as nul in",
    bg="Въведи сума по-голяма от нула",
    bn="শূন্যের বেশি একটি পরিমাণ লিখুন",
    ca="Introdueix un import superior a zero",
)
t(
    "Data note is too long",
    af="Datanota is te lank",
    bg="Бележката с данни е твърде дълга",
    bn="ডেটা নোট খুব দীর্ঘ",
    ca="La nota de dades és massa llarga",
)
t(
    "Memo is invalid",
    af="Memo is ongeldig",
    bg="Бележката е невалидна",
    bn="মেমো অবৈধ",
    ca="El memo no és vàlid",
)
t(
    "Memo is too long",
    af="Memo is te lank",
    bg="Бележката е твърде дълга",
    bn="মেমো খুব দীর্ঘ",
    ca="El memo és massa llarg",
)
t(
    "This recipient requires a memo",
    af="Hierdie ontvanger vereis 'n memo",
    bg="Този получател изисква бележка",
    bn="এই প্রাপকের একটি মেমো প্রয়োজন",
    ca="Aquest destinatari requereix un memo",
)
t(
    "This recipient requires a destination tag",
    af="Hierdie ontvanger vereis 'n bestemmingstiket",
    bg="Този получател изисква destination tag",
    bn="এই প্রাপকের একটি ডেস্টিনেশন ট্যাগ প্রয়োজন",
    ca="Aquest destinatari requereix una etiqueta de destinació",
)
t(
    "%@ isn't supported for sending.",
    af="%@ word nie vir stuur ondersteun nie.",
    bg="%@ не се поддържа за изпращане.",
    bn="%@ পাঠানোর জন্য সমর্থিত নয়।",
    ca="%@ no és compatible amb l’enviament.",
)
t(
    "Sending on %@ isn't available yet.",
    af="Stuur op %@ is nog nie beskikbaar nie.",
    bg="Изпращането в %@ все още не е налично.",
    bn="%@-এ পাঠানো এখনও উপলব্ধ নয়।",
    ca="L’enviament a %@ encara no està disponible.",
)
t(
    "The transaction is incomplete: %@.",
    af="Die transaksie is onvolledig: %@.",
    bg="Транзакцията е непълна: %@.",
    bn="লেনদেন অসম্পূর্ণ: %@।",
    ca="La transacció és incompleta: %@.",
)
t(
    "The network rejected the transaction: %@",
    af="Die netwerk het die transaksie verwerp: %@",
    bg="Мрежата отхвърли транзакцията: %@",
    bn="নেটওয়ার্ক লেনদেন প্রত্যাখ্যান করেছে: %@",
    ca="La xarxa ha rebutjat la transacció: %@",
)
t(
    "Too many recipients for one transaction",
    af="Te veel ontvangers vir een transaksie",
    bg="Твърде много получатели за една транзакция",
    bn="একটি লেনদেনের জন্য অনেক বেশি প্রাপক",
    ca="Massa destinataris per a una sola transacció",
)
t(
    "Not enough balance to cover the network fee",
    af="Nie genoeg saldo om die netwerkfooi te dek nie",
    bg="Няма достатъчно баланс за мрежовата такса",
    bn="নেটওয়ার্ক ফি কভার করার মতো পর্যাপ্ত ব্যালেন্স নেই",
    ca="Saldo insuficient per a la comissió de xarxa",
)
t(
    "Not enough balance to cover the amount and fee",
    af="Nie genoeg saldo om die bedrag en fooi te dek nie",
    bg="Няма достатъчно баланс за сумата и таксата",
    bn="পরিমাণ ও ফি কভার করার মতো পর্যাপ্ত ব্যালেন্স নেই",
    ca="Saldo insuficient per a l’import i la comissió",
)
t(
    "This wallet can't sign — it's watch-only.",
    af="Hierdie beursie kan nie teken nie — dit is slegs-kyk.",
    bg="Този портфейл не може да подписва — само за наблюдение.",
    bn="এই ওয়ালেট সাইন করতে পারে না — এটি শুধুমাত্র পর্যবেক্ষণযোগ্য।",
    ca="Aquesta cartera no pot signar: és només de consulta.",
)
t(
    "No wallet is selected to sign this transaction.",
    af="Geen beursie is gekies om hierdie transaksie te teken nie.",
    bg="Няма избран портфейл за подписване на тази транзакция.",
    bn="এই লেনদেন সাইন করার জন্য কোনো ওয়ালেট নির্বাচিত নেই।",
    ca="No hi ha cap cartera seleccionada per signar aquesta transacció.",
)
t(
    "Signing failed. The transaction was not sent.",
    af="Teken het misluk. Die transaksie is nie gestuur nie.",
    bg="Подписването неуспешно. Транзакцията не беше изпратена.",
    bn="সাইন ব্যর্থ হয়েছে। লেনদেন পাঠানো হয়নি।",
    ca="La signatura ha fallat. No s’ha enviat la transacció.",
)
t(
    "This wallet's recovery phrase couldn't be read.",
    af="Hierdie beursie se herstelfrase kon nie gelees word nie.",
    bg="Фразата за възстановяване на този портфейл не можа да се прочете.",
    bn="এই ওয়ালেটের রিকভারি বাক্যাংশ পড়া যায়নি।",
    ca="No s’ha pogut llegir la frase de recuperació d’aquesta cartera.",
)
t(
    "This wallet's private key couldn't be read for this network.",
    af="Hierdie beursie se privaatsleutel kon nie vir hierdie netwerk gelees word nie.",
    bg="Частният ключ на този портфейл не можа да се прочете за тази мрежа.",
    bn="এই নেটওয়ার্কের জন্য এই ওয়ালেটের প্রাইভেট কী পড়া যায়নি।",
    ca="No s’ha pogut llegir la clau privada d’aquesta cartera per a aquesta xarxa.",
)
t(
    "No active wallet was found for this receive screen.",
    af="Geen aktiewe beursie is vir hierdie ontvangskerm gevind nie.",
    bg="Не е намерен активен портфейл за този екран за получаване.",
    bn="এই রিসিভ স্ক্রিনের জন্য কোনো সক্রিয় ওয়ালেট পাওয়া যায়নি।",
    ca="No s’ha trobat cap cartera activa per a aquesta pantalla de recepció.",
)
t(
    "Aperture can't sign this transaction on this device yet.",
    af="Aperture kan hierdie transaksie nog nie op hierdie toestel teken nie.",
    bg="Aperture все още не може да подпише тази транзакция на това устройство.",
    bn="Aperture এখনও এই ডিভাইসে এই লেনদেন সাইন করতে পারে না।",
    ca="Aperture encara no pot signar aquesta transacció en aquest dispositiu.",
)
t(
    "Aperture couldn't confirm whether the transaction went through. Check the explorer before sending again.",
    af="Aperture kon nie bevestig of die transaksie deurgegaan het nie. Kontroleer die verkenner voordat jy weer stuur.",
    bg="Aperture не можа да потвърди дали транзакцията е минала. Провери експлорера преди да изпратиш отново.",
    bn="Aperture নিশ্চিত করতে পারেনি লেনদেন সম্পন্ন হয়েছে কিনা। আবার পাঠানোর আগে এক্সপ্লোরার পরীক্ষা করুন।",
    ca="Aperture no ha pogut confirmar si la transacció s’ha completat. Comprova l’explorador abans de tornar a enviar.",
)
t(
    "Couldn't reach the network to prepare the transaction. Please try again.",
    af="Kon nie die netwerk bereik om die transaksie voor te berei nie. Probeer asseblief weer.",
    bg="Мрежата не беше достъпна за подготовка на транзакцията. Моля, опитай отново.",
    bn="লেনদেন প্রস্তুত করতে নেটওয়ার্কে পৌঁছানো যায়নি। আবার চেষ্টা করুন।",
    ca="No s’ha pogut contactar la xarxa per preparar la transacció. Torna-ho a provar.",
)
t(
    "The signing key doesn't match this wallet's address. The transaction was not sent.",
    af="Die tekeningsleutel stem nie ooreen met hierdie beursie se adres nie. Die transaksie is nie gestuur nie.",
    bg="Ключът за подпис не съвпада с адреса на този портфейл. Транзакцията не беше изпратена.",
    bn="সাইনিং কী এই ওয়ালেটের ঠিকানার সাথে মেলে না। লেনদেন পাঠানো হয়নি।",
    ca="La clau de signatura no coincideix amb l’adreça d’aquesta cartera. No s’ha enviat la transacció.",
)
t(
    "A recipient can't be paid with what's left — lower an earlier amount or remove it",
    af="'n Ontvanger kan nie met wat oorbly betaal word nie — verlaag 'n vroeëre bedrag of verwyder dit",
    bg="Получател не може да бъде платен с остатъка — намали по-ранна сума или я премахни",
    bn="অবশিষ্ট দিয়ে একজন প্রাপককে দেওয়া যাবে না — আগের কোনো পরিমাণ কমান বা সরান",
    ca="No es pot pagar un destinatari amb el que queda: redueix un import anterior o elimina’l",
)
t(
    "This would drop your account below its required reserve",
    af="Dit sal jou rekening onder die vereiste reserwe laat daal",
    bg="Това би свалило акаунта ти под задължителния резерв",
    bn="এতে আপনার অ্যাকাউন্ট প্রয়োজনীয় রিজার্ভের নিচে নেমে যাবে",
    ca="Això deixaria el teu compte per sota de la reserva requerida",
)
t(
    "This new account needs a larger first payment to activate",
    af="Hierdie nuwe rekening benodig 'n groter eerste betaling om te aktiveer",
    bg="Този нов акаунт се нуждае от по-голямо първо плащане за активиране",
    bn="এই নতুন অ্যাকাউন্ট সক্রিয় করতে বড় প্রথম পেমেন্ট দরকার",
    ca="Aquest compte nou necessita un primer pagament més gran per activar-se",
)
t(
    "XRP family seeds (s…) aren't importable yet. Use a hex private key.",
    af="XRP-familie-saad (s…) kan nog nie ingevoer word nie. Gebruik 'n hex-privaatsleutel.",
    bg="Семената от семейството XRP (s…) все още не могат да се импортират. Използвай hex частен ключ.",
    bn="XRP পরিবারের সিড (s…) এখনও আমদানিযোগ্য নয়। একটি hex প্রাইভেট কী ব্যবহার করুন।",
    ca="Les llavors de la família XRP (s…) encara no es poden importar. Usa una clau privada hex.",
)
t(
    "Memo text must be 28 bytes or less.",
    af="Memo-teks moet 28 grepe of minder wees.",
    bg="Текстът на бележката трябва да е 28 байта или по-малко.",
    bn="মেমো টেক্সট ২৮ বাইট বা তার কম হতে হবে।",
    ca="El text del memo ha de ser de 28 bytes o menys.",
)

# Fees
t(
    "Network fee is set by the protocol",
    af="Netwerkfooi word deur die protokol gestel",
    bg="Мрежовата такса се определя от протокола",
    bn="নেটওয়ার্ক ফি প্রোটোকল দ্বারা নির্ধারিত",
    ca="La comissió de xarxa la fixa el protocol",
)
t(
    "Includes an L1 data fee",
    af="Sluit 'n L1-datafooi in",
    bg="Включва L1 такса за данни",
    bn="একটি L1 ডেটা ফি অন্তর্ভুক্ত",
    ca="Inclou una comissió de dades L1",
)
t(
    "Includes pubdata cost in the gas limit",
    af="Sluit pubdata-koste in die gaslimiet in",
    bg="Включва pubdata разход в лимита за газ",
    bn="গ্যাস সীমায় pubdata খরচ অন্তর্ভুক্ত",
    ca="Inclou el cost de pubdata al límit de gas",
)
t(
    "Final fee depends on the coins selected",
    af="Finale fooi hang af van die gekose munte",
    bg="Крайната такса зависи от избраните монети",
    bn="চূড়ান্ত ফি নির্বাচিত কয়েনের উপর নির্ভর করে",
    ca="La comissió final depèn de les monedes seleccionades",
)
t(
    "Final fee is refined by a dry run before signing",
    af="Finale fooi word deur 'n droë lopie verfyn voor teken",
    bg="Крайната такса се уточнява с пробно изпълнение преди подписване",
    bn="সাইন করার আগে ড্রাই রান দিয়ে চূড়ান্ত ফি পরিমার্জিত হয়",
    ca="La comissió final es refina amb una prova en sec abans de signar",
)
t(
    "Fee shown assumes no free or staked resources",
    af="Fooi getoon aanvaar geen gratis of gestakte hulpbronne nie",
    bg="Показаната такса предполага липса на безплатни или стейкнати ресурси",
    bn="দেখানো ফি ধরে নেয় কোনো বিনামূল্যে বা স্টেক করা রিসোর্স নেই",
    ca="La comissió mostrada assumeix que no hi ha recursos gratuïts ni en stake",
)
t(
    "The only adjustable part is the priority tip",
    af="Die enigste verstelbare deel is die prioriteitfooi",
    bg="Единствената регулируема част е priority tip",
    bn="একমাত্র সমন্বয়যোগ্য অংশ হল প্রাধান্য টিপ",
    ca="L’única part ajustable és la propina de prioritat",
)
t(
    "You're only charged the network base fee at inclusion",
    af="Jy word slegs die netwerk-basiese fooi by insluiting gehef",
    bg="Таксува се само базовата мрежова такса при включване",
    bn="অন্তর্ভুক্তির সময় শুধু নেটওয়ার্ক বেস ফি নেওয়া হয়",
    ca="Només se’t cobra la comissió base de xarxa en la inclusió",
)
t(
    "Max gas is capped automatically; only used gas is charged",
    af="Maks gas word outomaties beperk; slegs gebruikte gas word gehef",
    bg="Макс. газ се ограничава автоматично; таксува се само използваният газ",
    bn="ম্যাক্স গ্যাস স্বয়ংক্রিয়ভাবে সীমিত; শুধু ব্যবহৃত গ্যাস চার্জ হয়",
    ca="El gas màxim es limita automàticament; només es cobra el gas usat",
)
t(
    "Includes 0.00125 NEAR storage deposit; unused gas is refunded",
    af="Sluit 0.00125 NEAR-bergingsdeposito in; ongebruikte gas word terugbetaal",
    bg="Включва 0,00125 NEAR депозит за съхранение; неизползваният газ се възстановява",
    bn="০.০০১২৫ NEAR স্টোরেজ ডিপোজিট অন্তর্ভুক্ত; অব্যবহৃত গ্যাস ফেরত দেওয়া হয়",
    ca="Inclou un dipòsit d’emmagatzematge de 0,00125 NEAR; el gas no usat es reemborsa",
)
t(
    "Token sends may need a recipient token account (extra rent)",
    af="Token-stuur mag 'n ontvanger-tokenrekening benodig (ekstra huur)",
    bg="Изпращането на токени може да изисква token акаунт на получателя (доп. rent)",
    bn="টোকেন পাঠাতে প্রাপকের টোকেন অ্যাকাউন্ট লাগতে পারে (অতিরিক্ত rent)",
    ca="Els enviaments de tokens poden necessitar un compte de token del destinatari (rent extra)",
)

# Market / home
t(
    "Market data is unavailable. Pull to refresh when the network is back.",
    af="Markdata is nie beskikbaar nie. Trek om te herlaai wanneer die netwerk terug is.",
    bg="Пазарните данни не са налични. Дръпни за опресняване, когато мрежата се върне.",
    bn="মার্কেট ডেটা উপলব্ধ নয়। নেটওয়ার্ক ফিরলে রিফ্রেশ করতে টানুন।",
    ca="Les dades de mercat no estan disponibles. Estira per actualitzar quan torni la xarxa.",
)
t(
    "Using saved market data. Pull to refresh for live prices.",
    af="Gebruik gestoorde markdata. Trek om te herlaai vir lewendige pryse.",
    bg="Използват се запазени пазарни данни. Дръпни за опресняване за актуални цени.",
    bn="সংরক্ষিত মার্কেট ডেটা ব্যবহার হচ্ছে। লাইভ দামের জন্য রিফ্রেশ করতে টানুন।",
    ca="S’estan usant dades de mercat desades. Estira per actualitzar els preus en directe.",
)
t(
    "Home balance and activity use the selected path only (default Phantom). Switch paths in Receive.",
    af="Tuissaldo en aktiwiteit gebruik slegs die gekose pad (standaard Phantom). Wissel paaie by Ontvang.",
    bg="Началният баланс и активността използват само избрания път (по подразбиране Phantom). Смени пътища в Получи.",
    bn="হোম ব্যালেন্স ও অ্যাক্টিভিটি শুধু নির্বাচিত পাথ ব্যবহার করে (ডিফল্ট Phantom)। রিসিভে পাথ বদলান।",
    ca="El saldo i l’activitat d’inici usen només la ruta seleccionada (per defecte Phantom). Canvia les rutes a Rep.",
)
t(
    "Selected path only — home total may include other paths",
    af="Slegs geselekteerde pad — tuistotaal mag ander paaie insluit",
    bg="Само избраният път — общият баланс може да включва други пътища",
    bn="শুধু নির্বাচিত পাথ — হোম মোট অন্য পাথ অন্তর্ভুক্ত করতে পারে",
    ca="Només la ruta seleccionada: el total d’inici pot incloure altres rutes",
)

# Share copy
t(
    "Transaction failed. Shared from Aperture.",
    af="Transaksie het misluk. Gedeel vanaf Aperture.",
    bg="Транзакцията неуспешна. Споделено от Aperture.",
    bn="লেনদেন ব্যর্থ। Aperture থেকে শেয়ার করা।",
    ca="La transacció ha fallat. Compartit des d’Aperture.",
)
t(
    "Sent with Aperture. A clean self-custody wallet for crypto you control.",
    af="Gestuur met Aperture. 'n Skoon self-bewaringsbeursie vir kripto wat jy beheer.",
    bg="Изпратено с Aperture. Чист self-custody портфейл за крипто, което контролираш.",
    bn="Aperture দিয়ে পাঠানো। আপনার নিয়ন্ত্রিত ক্রিপ্টোর জন্য পরিচ্ছন্ন সেলফ-কাস্টডি ওয়ালেট।",
    ca="Enviat amb Aperture. Una cartera d’autocustòdia neta per al cripto que controles.",
)
t(
    "Confirming on-chain with Aperture. A clean self-custody wallet for crypto you control.",
    af="Bevestig tans on-chain met Aperture. 'n Skoon self-bewaringsbeursie vir kripto wat jy beheer.",
    bg="Потвърждаване on-chain с Aperture. Чист self-custody портфейл за крипто, което контролираш.",
    bn="Aperture দিয়ে অন-চেইন নিশ্চিত হচ্ছে। আপনার নিয়ন্ত্রিত ক্রিপ্টোর জন্য পরিচ্ছন্ন সেলফ-কাস্টডি ওয়ালেট।",
    ca="S’està confirmant on-chain amb Aperture. Una cartera d’autocustòdia neta per al cripto que controles.",
)
t(
    "Opens an email to support with diagnostics",
    af="Maak 'n e-pos na ondersteuning oop met diagnostiek",
    bg="Отваря имейл до поддръжката с диагностика",
    bn="ডায়াগনস্টিকসহ সহায়তায় ইমেইল খোলে",
    ca="Obre un correu a assistència amb diagnòstics",
)

# Reset / passphrase
t(
    "This wallet has a passphrase. Enter it to derive Phantom and Trust Wallet Solana paths — it never leaves this iPhone.",
    af="Hierdie beursie het 'n wagfrase. Voer dit in om Phantom- en Trust Wallet-Solana-paaie af te lei — dit verlaat nooit hierdie iPhone nie.",
    bg="Този портфейл има паролна фраза. Въведи я, за да извлечеш Solana пътища на Phantom и Trust Wallet — никога не напуска този iPhone.",
    bn="এই ওয়ালেটের একটি পাসফ্রেজ আছে। Phantom ও Trust Wallet Solana পাথ ডেরাইভ করতে এটি লিখুন — এটি এই iPhone ছাড়ে না।",
    ca="Aquesta cartera té una frase de contrasenya. Introdueix-la per derivar rutes Solana de Phantom i Trust Wallet: no surt d’aquest iPhone.",
)
t(
    "Typing the word below confirms the reset. This erases wallets, keys, and settings on this iPhone. iCloud backups on this Apple ID are not deleted and can still restore a wallet.",
    af="Die tik van die woord hieronder bevestig die herstel. Dit wis beursies, sleutels en instellings op hierdie iPhone. iCloud-rugsteune op hierdie Apple ID word nie uitgevee nie en kan steeds 'n beursie herstel.",
    bg="Въвеждането на думата по-долу потвърждава нулирането. Това изтрива портфейли, ключове и настройки на този iPhone. iCloud резервните копия на този Apple ID не се изтриват и все още могат да възстановят портфейл.",
    bn="নিচের শব্দটি টাইপ করলে রিসেট নিশ্চিত হয়। এতে এই iPhone-এর ওয়ালেট, কী ও সেটিংস মুছে যায়। এই Apple ID-এর iCloud ব্যাকআপ মুছে যায় না এবং এখনও ওয়ালেট পুনরুদ্ধার করতে পারে।",
    ca="Escriure la paraula de sota confirma el restabliment. Això esborra carteres, claus i ajustaments d’aquest iPhone. Les còpies d’iCloud d’aquest Apple ID no s’eliminen i encara poden restaurar una cartera.",
)
t(
    "Couldn’t erase Aperture. Your wallets and keys are still on this iPhone and the app stays locked. Try again, or restore from your recovery phrase after a reinstall.",
    bn="Aperture মুছে ফেলা যায়নি। আপনার ওয়ালেট ও কী এখনও এই iPhone-এ আছে এবং অ্যাপ লক থাকে। আবার চেষ্টা করুন, অথবা পুনরায় ইনস্টলের পর রিকভারি বাক্যাংশ দিয়ে পুনরুদ্ধার করুন।",
)
t(
    "Use the same account index across Ethereum-compatible networks. Mnemonic wallets save each chain's correctly derived address; imported-key and watch-only wallets reuse the same 0x address.",
    af="Gebruik dieselfde rekeningindeks oor Ethereum-versoenbare netwerke. Mnemoniese beursies stoor elke ketting se korrek afgeleide adres; ingevoerde-sleutel- en slegs-kyk-beursies hergebruik dieselfde 0x-adres.",
    bg="Използвай същия индекс на акаунт в Ethereum-съвместими мрежи. Мнемоничните портфейли запазват правилно извлечения адрес за всяка верига; портфейлите с импортиран ключ и само за наблюдение преизползват същия 0x адрес.",
    bn="Ethereum-সামঞ্জস্যপূর্ণ নেটওয়ার্ক জুড়ে একই অ্যাকাউন্ট ইনডেক্স ব্যবহার করুন। মnemonic ওয়ালেট প্রতিটি চেইনের সঠিকভাবে ডেরাইভ করা ঠিকানা সংরক্ষণ করে; ইমপোর্টেড-কী ও শুধুমাত্র-পর্যবেক্ষণ ওয়ালেট একই 0x ঠিকানা পুনরায় ব্যবহার করে।",
    ca="Usa el mateix índex de compte a les xarxes compatibles amb Ethereum. Les carteres mnemòniques desen l’adreça derivada correctament de cada cadena; les de clau importada i només de consulta reutilitzen la mateixa adreça 0x.",
)

# Biometric unlock copy (af only flagged)
t(
    "Unlock Aperture and confirm transactions with Optic ID — without typing your PIN every time.",
    af="Ontsluit Aperture en bevestig transaksies met Optic ID — sonder om jou PIN elke keer te tik.",
)
t(
    "Unlock Aperture and confirm transactions with your fingerprint — without typing your PIN every time.",
    af="Ontsluit Aperture en bevestig transaksies met jou vingerafdruk — sonder om jou PIN elke keer te tik.",
)
t(
    "Unlock Aperture and confirm transactions with device biometrics — without typing your PIN every time.",
    af="Ontsluit Aperture en bevestig transaksies met toestelbiometrie — sonder om jou PIN elke keer te tik.",
)

# Chain blurbs (af + bn mostly)
t(
    "Aptos is a Move-based layer-one blockchain.",
    af="Aptos is 'n Move-gebaseerde laag-een-blokketting.",
    bn="Aptos হল Move-ভিত্তিক লেয়ার-ওয়ান ব্লকচেইন।",
)
t(
    "Avalanche is a smart-contract platform built around fast finality and subnet architecture.",
    af="Avalanche is 'n slimkontrak-platform gebou rondom vinnige finaliteit en subnet-argitektuur.",
    bn="Avalanche দ্রুত চূড়ান্ততা ও সাবনেট আর্কিটেকচারকে কেন্দ্র করে নির্মিত একটি স্মার্ট-কন্ট্রাক্ট প্ল্যাটফর্ম।",
)
t(
    "BNB is the native asset of the BNB Chain ecosystem.",
    af="BNB is die inheemse bate van die BNB Chain-ekosisteem.",
    bn="BNB হল BNB Chain ইকোসিস্টেমের নেটিভ অ্যাসেট।",
)
t(
    "Bitcoin Cash is a Bitcoin-family digital currency focused on low-fee payments.",
    af="Bitcoin Cash is 'n Bitcoin-familie digitale geldeenheid gerig op lae-fooi-betalings.",
    bn="Bitcoin Cash হল কম-ফি পেমেন্টে মনোযোগী Bitcoin-পরিবারের ডিজিটাল মুদ্রা।",
)
t(
    "Celo is a mobile-first EVM network focused on payments and public goods.",
    af="Celo is 'n selfoon-eerste EVM-netwerk gerig op betalings en openbare goedere.",
    bn="Celo হল পেমেন্ট ও পাবলিক গুডসে মনোযোগী মোবাইল-প্রথম EVM নেটওয়ার্ক।",
)
t(
    "Dai is a decentralized US dollar stablecoin.",
    af="Dai is 'n gedesentraliseerde VS-dollar-stablecoin.",
    bn="Dai হল একটি বিকেন্দ্রীকৃত মার্কিন ডলার স্টেবলকয়েন।",
)
t(
    "Dogecoin is a proof-of-work digital currency with fast, low-cost transfers.",
    af="Dogecoin is 'n proof-of-work digitale geldeenheid met vinnige, lae-koste oordragte.",
    bn="Dogecoin দ্রুত, কম-খরচের ট্রান্সফারসহ একটি proof-of-work ডিজিটাল মুদ্রা।",
)
t(
    "Ethereum is a programmable blockchain for decentralized applications and tokens.",
    af="Ethereum is 'n programmeerbare blokketting vir gedesentraliseerde toepassings en tokens.",
    bg="Ethereum е програмируема блокчейн за децентрализирани приложения и токени.",
    bn="Ethereum বিকেন্দ্রীকৃত অ্যাপ ও টোকেনের জন্য একটি প্রোগ্রামযোগ্য ব্লকচেইন।",
    ca="Ethereum és una cadena de blocs programable per a aplicacions i tokens descentralitzats.",
)
t(
    "Litecoin is a proof-of-work digital currency derived from Bitcoin.",
    af="Litecoin is 'n proof-of-work digitale geldeenheid afgelei van Bitcoin.",
    bn="Litecoin Bitcoin থেকে উদ্ভূত একটি proof-of-work ডিজিটাল মুদ্রা।",
)
t(
    "NEAR is a proof-of-stake smart-contract network using sharded infrastructure.",
    af="NEAR is 'n proof-of-stake slimkontrak-netwerk met sharded infrastruktuur.",
    bn="NEAR শার্ডেড অবকাঠামো ব্যবহারকারী একটি proof-of-stake স্মার্ট-কন্ট্রাক্ট নেটওয়ার্ক।",
)
t(
    "POL is the ecosystem token for Polygon networks.",
    af="POL is die ekosisteem-token vir Polygon-netwerke.",
    bn="POL হল Polygon নেটওয়ার্কের ইকোসিস্টেম টোকেন।",
)
t(
    "Polkadot connects specialized blockchains through a shared security model.",
    af="Polkadot verbind gespesialiseerde blokkettings deur 'n gedeelde sekuriteitsmodel.",
    bn="Polkadot ভাগ করা নিরাপত্তা মডেলের মাধ্যমে বিশেষায়িত ব্লকচেইন সংযুক্ত করে।",
)
t(
    "Solana is a high-throughput smart-contract network optimized for low-fee applications.",
    af="Solana is 'n hoë-deurset slimkontrak-netwerk geoptimaliseer vir lae-fooi-toepassings.",
    bg="Solana е смарт-контракт мрежа с висок капацитет, оптимизирана за приложения с ниски такси.",
    bn="Solana কম-ফি অ্যাপের জন্য অপ্টিমাইজড উচ্চ-থ্রুপুট স্মার্ট-কন্ট্রাক্ট নেটওয়ার্ক।",
    ca="Solana és una xarxa de contractes intel·ligents d’alt rendiment optimitzada per a apps de comissions baixes.",
)
t(
    "Stellar is a payments network for asset issuance and settlement.",
    af="Stellar is 'n betalingsnetwerk vir bate-uitreiking en vereffening.",
    bn="Stellar সম্পদ ইস্যু ও সেটেলমেন্টের জন্য একটি পেমেন্টস নেটওয়ার্ক।",
)
t(
    "Sui is an object-centric layer-one blockchain built for high-performance applications.",
    af="Sui is 'n objek-gesentreerde laag-een-blokketting gebou vir hoë-prestasie-toepassings.",
    bn="Sui উচ্চ-পারফরম্যান্স অ্যাপের জন্য নির্মিত অবজেক্ট-কেন্দ্রিক লেয়ার-ওয়ান ব্লকচেইন।",
)
t(
    "Tether is a US dollar stablecoin used across multiple blockchain networks.",
    af="Tether is 'n VS-dollar-stablecoin wat oor verskeie blokkettingnetwerke gebruik word.",
    bn="Tether একাধিক ব্লকচেইন নেটওয়ার্কে ব্যবহৃত একটি মার্কিন ডলার স্টেবলকয়েন।",
)
t(
    "Toncoin is the native asset of The Open Network.",
    af="Toncoin is die inheemse bate van The Open Network.",
    bn="Toncoin হল The Open Network-এর নেটিভ অ্যাসেট।",
)
t(
    "TRON is a smart-contract network used for token transfers and decentralized applications.",
    af="TRON is 'n slimkontrak-netwerk vir token-oordragte en gedesentraliseerde toepassings.",
    bn="TRON টোকেন ট্রান্সফার ও বিকেন্দ্রীকৃত অ্যাপের জন্য ব্যবহৃত একটি স্মার্ট-কন্ট্রাক্ট নেটওয়ার্ক।",
)
t(
    "USD Coin is a regulated US dollar stablecoin.",
    af="USD Coin is 'n gereguleerde VS-dollar-stablecoin.",
    bn="USD Coin হল একটি নিয়ন্ত্রিত মার্কিন ডলার স্টেবলকয়েন।",
)
t(
    "XRP is the native asset used by XRP Ledger for settlement and fees.",
    af="XRP is die inheemse bate wat deur XRP Ledger vir vereffening en fooie gebruik word.",
    bn="XRP হল XRP Ledger-এর সেটেলমেন্ট ও ফির জন্য ব্যবহৃত নেটিভ অ্যাসেট।",
)
t(
    "Destination tag must be a number from 0 to 4,294,967,295.",
    af="Bestemmingstiket moet 'n getal van 0 tot 4,294,967,295 wees.",
    bn="ডেস্টিনেশন ট্যাগ ০ থেকে ৪,২৯৪,৯৬৭,২৯৫ পর্যন্ত একটি সংখ্যা হতে হবে।",
)
t(
    "Memo hash must be exactly 32 bytes, written as 64 hex characters.",
    af="Memo-hash moet presies 32 grepe wees, geskryf as 64 heksadesimale karakters.",
    bn="মেমো হ্যাশ ঠিক ৩২ বাইট হতে হবে, ৬৪টি হেক্স অক্ষরে লেখা।",
)
t(
    "Memo ID must be a whole number from 0 to 18,446,744,073,709,551,615.",
    af="Memo-ID moet 'n heelgetal van 0 tot 18,446,744,073,709,551,615 wees.",
    bn="মেমো ID ০ থেকে ১৮,৪৪৬,৭৪৪,০৭৩,৭০৯,৫৫১,৬১৫ পর্যন্ত একটি পূর্ণসংখ্যা হতে হবে।",
)

# === Quality fixes beyond flags ===
# Arabic: Slot mistranslated as optical aperture (brand collision)
EXTRA_QUALITY = [
    {
        "key": "Slot",
        "lang": "ar",
        "old": "الفتحة",
        "new": "Slot",
        "reason": "Solana slot must not be الفتحة (optical aperture / brand collision); keep Latin Slot",
    },
    {
        "key": "~ next slot (~0.4 s)",
        "lang": "ar",
        "old": "~ الفتحة التالية (~٠٫٤ ث)",
        "new": "~ الـ Slot التالي (~٠٫٤ ث)",
        "reason": "Solana slot; avoid الفتحة which means aperture and confuses brand",
    },
    {
        "key": "Self",
        "lang": "ar",
        "old": "الذات",
        "new": "نفسي",
        "reason": "Send-to-self UI; نفسي is natural, الذات is philosophical",
    },
    # Catalan Slot physical "Ranura" is wrong for Solana
    {
        "key": "Slot",
        "lang": "ca",
        "old": "Ranura",
        "new": "Slot",
        "reason": "Solana technical term; keep Slot not physical 'ranura'",
    },
    # Afrikaans Gleuf = physical slot
    {
        "key": "Slot",
        "lang": "af",
        "old": "Gleuf",
        "new": "Slot",
        "reason": "Solana technical term; keep Slot not physical 'gleuf'",
    },
]


def load_current_values() -> dict[str, dict[str, str | None]]:
    """key -> lang -> current val from pairs_*.jsonl"""
    out: dict[str, dict[str, str | None]] = {}
    for lang in ("af", "ar", "bg", "bn", "ca"):
        path = DIR / f"pairs_{lang}.jsonl"
        with path.open(encoding="utf-8") as f:
            for line in f:
                o = json.loads(line)
                out.setdefault(o["key"], {})[lang] = o.get("val")
    return out


def main() -> None:
    current = load_current_values()
    fixes: list[dict] = []
    lang_counts = {lang: 0 for lang in ("af", "ar", "bg", "bn", "ca")}
    seen: set[tuple[str, str]] = set()

    for key, langs in T.items():
        if key in SKIP_KEYS:
            continue
        for lang, new in langs.items():
            if (key, lang) in seen:
                continue
            old = current.get(key, {}).get(lang)
            # If key missing from pairs, still emit with old=None for missing localizations
            if old is None and key not in current:
                # might still exist as missing localization — allow
                pass
            if old == new:
                continue  # no churn
            # Only fix when currently English / null / clearly untranslated
            en = key  # English key is the source string for most catalog entries
            if old is not None and old != en and old != "":
                # Already translated to something else — only override if we explicitly
                # want quality fix (handled in EXTRA_QUALITY)
                continue
            if new == en:
                # Translation equals English (loanword) — still useful if old was null
                if old is not None:
                    continue
            seen.add((key, lang))
            fixes.append(
                {
                    "key": key,
                    "lang": lang,
                    "old": old,
                    "new": new,
                    "reason": "Untranslated user-facing string; native wallet UI phrasing",
                }
            )
            lang_counts[lang] += 1

    for row in EXTRA_QUALITY:
        k, lang = row["key"], row["lang"]
        if (k, lang) in seen:
            continue
        cur = current.get(k, {}).get(lang)
        if cur == row["new"]:
            continue
        # Prefer actual current as old
        row = dict(row)
        if cur is not None:
            row["old"] = cur
        if cur == row["new"]:
            continue
        seen.add((k, lang))
        fixes.append(row)
        lang_counts[lang] += 1

    # Stable sort for reproducibility
    fixes.sort(key=lambda r: (r["lang"], r["key"]))

    fixes_path = DIR / "fixes.jsonl"
    with fixes_path.open("w", encoding="utf-8") as f:
        for row in fixes:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    flagged_total = 679
    report = {
        "lang_counts": lang_counts,
        "notes": (
            "Reviewed all 679 flagged rows for af/ar/bg/bn/ca. "
            "Skipped language-neutral format strings, brands (Coinbase, Trust Wallet Assets), "
            "protocol names (Replace-By-Fee, xpub/ypub/zpub, Nonce, Hash), filenames, and "
            "false-positive unicode placeholder mismatches. "
            "Translated missing/untranslated user-facing wallet UI (send/receive, fees, security, "
            "errors, market, chain blurbs). "
            "Quality: fixed Arabic Slot→الفتحة brand/optical collision to Latin Slot; "
            "Arabic Self→نفسي; Catalan/Afrikaans Slot physical mistranslations. "
            "Aperture brand kept Latin everywhere."
        ),
        "reviewed_flagged": flagged_total,
        "reviewed_total_estimate": 2425 * 5,
        "fixes_total": len(fixes),
    }
    (DIR / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {len(fixes)} fixes -> {fixes_path}")
    print("lang_counts", lang_counts)


if __name__ == "__main__":
    main()
