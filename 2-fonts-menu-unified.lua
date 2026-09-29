-- Patch unificata: scorciatoia "Font" nel ConfigDialog (pannello Dimensione font)
-- Un tap sulla scorciatoia apre una modale ButtonDialog con l'elenco dei font
-- (stessa sorgente del menù: face_table / cre.getFontFaces).
-- Il ConfigDialog resta aperto sotto la modale.
-- Tap su un font → applica subito; la chiusura dipende dalla modalità attiva:
--   * "floating" → modale libera centrata (80% larghezza) con header |Font  Close|
--   * "bottom"   → finestra fissa ancorata in basso a tutta larghezza, senza
--                  header (tap fuori o Back la chiude).
-- LONG-PRESS sulla scorciatoia "Font: nome" → piccolo modale che permette di
-- scegliere la modalità (Finestra libera / Finestra in basso); la scelta viene
-- salvata in G_reader_settings ("fonts_menu_mode") e resta valida per sempre.
-- Solo documenti CRE (EPUB/TXT/...): i PDF usano KoptOptions e non
-- vengono toccati.
-- La scorciatoia "Font" è disegnata con il font attivo del documento:
-- testo "CARATTERE: Lora" (etichetta tradotta in MAIUSCOLO + ":" + nome
-- originale del font), senza sottolineatura, e si aggiorna non appena si
-- sceglie un altro font nel modale.

local CreOptions = require("ui/data/creoptions")
local ReaderFont = require("apps/reader/modules/readerfont")
local UIManager = require("ui/uimanager")
local ConfigDialog = require("ui/widget/configdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Button = require("ui/widget/button")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
-- Maiuscole UTF-8 per l'etichetta della scorciatoia (utf8proc):
-- gestisce gli accenti delle traduzioni, a differenza di string.upper.
local Utf8Proc = require("ffi/utf8proc")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
-- Modale ancorata in basso a tutta larghezza (modalità "bottom"):
-- BottomContainer == container usato dallo stesso ConfigDialog.
-- ScrollableContainer per la larghezza della scrollbar (fuori da self.width).
local Device = require("device")
local Screen = Device.screen
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local logger = require("logger")
-- Traduzioni: la patch viene caricata con priorità "late" (reader.lua),
-- quindi dopo che la lingua del dispositivo è già stata applicata a gettext.
-- `gettext` è la stessa tabella `_`: esplicita perché serve anche
-- gettext.current_lang (lingua del catalogo caricato) per le etichette
-- della modalità, che NON esistono nei .mo di KOReader.
local gettext = require("gettext")
local _ = gettext

local SHORTCUT_NAME = "font_face_shortcut"
-- Etichetta tradotta e messa in maiuscolo, con i due punti:
--   it_IT → "CARATTERE:"   en → "FONT:"
-- Calcolata una volta sola a caricamento (dopo l'applicazione della lingua),
-- fuori dai loop dove la variabile `_` di gettext verrebbe oscurata.
local SHORTCUT_LABEL = _("Font")
local SHORTCUT_LABEL_UPPER = Utf8Proc.uppercase_dumb(SHORTCUT_LABEL) .. ":"
-- Stessa size della riga nel ConfigDialog (item_font_size): il FontFaceObj
-- del font attivo viene creato a questa size → pass-through in Font:getFace.
local SHORTCUT_PREVIEW_SIZE = 20
local shortcut_option = nil -- opzione iniettata (tabella condivisa in CreOptions)
local active_font_dialog = nil
local active_mode_dialog = nil
-- Forward reference: usata da postProcessShortcutRow (installato subito),
-- definita in fondo al file. Con `local` dichiarato PRIMA della funzione che
-- la usa, l'assegnazione successiva viene vista dall'upvalue.
local showModeChooser

-- ─── 0. Modalità preferita (persistente) + etichette tradotte ───────────────
-- Chiave: G_reader_settings["fonts_menu_mode"] = "bottom" | "floating".
-- Default "bottom" (finestra fissa in basso) quando l'impostazione non esiste.
-- G_reader_settings fa flush all'uscita di KOReader: nessun I/O extra nostro.

local MODE_SETTING = "fonts_menu_mode"
local MODE_BOTTOM = "bottom"
local MODE_FLOATING = "floating"
-- Stesso checkmark di ui/widget/button.lua (Button.checkmark): due spazi + ✓
local MODE_CHECKMARK = "  \u{2713}"

local function getFontMenuMode()
    local mode = G_reader_settings:readSetting(MODE_SETTING)
    if mode == MODE_FLOATING or mode == MODE_BOTTOM then
        return mode
    end
    return MODE_BOTTOM
end

local function setFontMenuMode(mode)
    G_reader_settings:saveSetting(MODE_SETTING, mode)
end

-- Etichette delle due modalità. I msgid NON sono nei cataloghi KOReader
-- (l10n/*.mo), quindi gettext restituirebbe l'inglese: tabella interna con
-- tutte le lingue shipplate, risolta per prefisso (it_IT → it → en).
local MODE_LABELS = {
    en = { floating = "Free window", bottom = "Bottom window" },
    af_ZA = { floating = "Vrye venster", bottom = "Onderste venster" },
    ar = { floating = "نافذة حرة", bottom = "نافذة سفلية" },
    be = { floating = "Вольнае акно", bottom = "Ніжняе акно" },
    bg_BG = { floating = "Свободен прозорец", bottom = "Долен прозорец" },
    bn = { floating = "স্বাধীন উইন্ডো", bottom = "নিচের উইন্ডো" },
    ca = { floating = "Finestra lliure", bottom = "Finestra inferior" },
    cs = { floating = "Volné okno", bottom = "Dolní okno" },
    cy = { floating = "Ffenestr rydd", bottom = "Ffenestr waelod" },
    da = { floating = "Frit vindue", bottom = "Bundvindue" },
    de = { floating = "Freies Fenster", bottom = "Unteres Fenster" },
    el = { floating = "Ελεύθερο παράθυρο", bottom = "Κάτω παράθυρο" },
    en_GB = { floating = "Free window", bottom = "Bottom window" },
    eo = { floating = "Libera fenestro", bottom = "Suba fenestro" },
    es = { floating = "Ventana libre", bottom = "Ventana inferior" },
    et = { floating = "Vaba aken", bottom = "Alumine aken" },
    eu = { floating = "Leiho aske", bottom = "Beheko leiho" },
    fa = { floating = "پنجره آزاد", bottom = "پنجره پایین" },
    fi = { floating = "Vapaa ikkuna", bottom = "Alaikkuna" },
    fr = { floating = "Fenêtre libre", bottom = "Fenêtre en bas" },
    ga = { floating = "Fuinneog saor", bottom = "Fuinneog bun" },
    gl = { floating = "Xanela libre", bottom = "Xanela inferior" },
    he = { floating = "חלון חופשי", bottom = "חלון תחתון" },
    hi = { floating = "स्वतंत्र विंडो", bottom = "नीचे की विंडो" },
    hr = { floating = "Slobodni prozor", bottom = "Donji prozor" },
    hu = { floating = "Szabad ablak", bottom = "Alsó ablak" },
    ia = { floating = "Fenestra libre", bottom = "Infima fenestra" },
    id = { floating = "Jendela bebas", bottom = "Jendela bawah" },
    ie = { floating = "Libera fenere", bottom = "Basi fenere" },
    it_IT = { floating = "Finestra libera", bottom = "Finestra in basso" },
    ja = { floating = "フリーウィンドウ", bottom = "下部ウィンドウ" },
    ka = { floating = "თავისუფალი ფანჯარა", bottom = "ქვედა ფანჯარა" },
    kab = { floating = "Tagerrust taggarant", bottom = "Tagerrust addawinant" },
    kn = { floating = "ಸ್ವತಂತ್ರ ವಿಂಡೋ", bottom = "ಕೆಳಗಿನ ವಿಂಡೋ" },
    ko_KR = { floating = "자유 창", bottom = "하단 창" },
    lt_LT = { floating = "Laisvas langas", bottom = "Apatinis langas" },
    lv = { floating = "Brīvs logs", bottom = "Apakšējais logs" },
    mk = { floating = "Слободен прозорец", bottom = "Долен прозорец" },
    ms = { floating = "Tetingkap bebas", bottom = "Tetingkap bawah" },
    nb_NO = { floating = "Fritt vindu", bottom = "Bunnvindu" },
    nl_NL = { floating = "Vrij venster", bottom = "Onderste venster" },
    ["or"] = { floating = "ମୁକ୍ତ ଉଇଣ୍ଡୋ", bottom = "ତଳ ଉଇଣ୍ଡୋ" }, -- codice lingua "or" (riservata in Lua)
    pl = { floating = "Wolne okno", bottom = "Dolne okno" },
    pt_BR = { floating = "Janela livre", bottom = "Janela inferior" },
    pt_PT = { floating = "Janela livre", bottom = "Janela inferior" },
    ro = { floating = "Fereastră liberă", bottom = "Fereastră de jos" },
    ro_MD = { floating = "Fereastră liberă", bottom = "Fereastră de jos" },
    ru = { floating = "Свободное окно", bottom = "Нижнее окно" },
    si = { floating = "නිදහස් කවුළුව", bottom = "පහළ කවුළුව" },
    sk = { floating = "Voľné okno", bottom = "Dolné okno" },
    sl = { floating = "Prosto okno", bottom = "Spodnje okno" },
    sr = { floating = "Слободан прозор", bottom = "Доњи прозор" },
    sv = { floating = "Fritt fönster", bottom = "Nedre fönster" },
    th = { floating = "หน้าต่างอิสระ", bottom = "หน้าต่างด้านล่าง" },
    tr = { floating = "Serbest pencere", bottom = "Alt pencere" },
    uk = { floating = "Вільне вікно", bottom = "Нижнє вікно" },
    ur = { floating = "آزاد ونڈو", bottom = "نیچے کی ونڈو" },
    vi = { floating = "Cửa sổ tự do", bottom = "Cửa sổ dưới" },
    zh_CN = { floating = "自由窗口", bottom = "底部窗口" },
    zh_TW = { floating = "自由視窗", bottom = "底部視窗" },
}

-- Lingua corrente: catalogo effettivamente caricato da gettext ("it_IT",
-- "de", ...); "C" = inglese/nessun catalogo → fallback su "en".
local function currentLangCode()
    local lang = gettext.current_lang
    if not lang or lang == "C" or lang == "" then
        lang = G_reader_settings:readSetting("language")
    end
    if not lang or lang == "C" or lang == "" then
        return "en"
    end
    if MODE_LABELS[lang] then
        return lang
    end
    -- it_IT → it, pt_BR → pt (tutti i codici base sono minuscoli)
    local base = lang:sub(1, 2):lower()
    if MODE_LABELS[base] then
        return base
    end
    return "en"
end

local function modeLabel(mode)
    local labels = MODE_LABELS[currentLangCode()]
    if labels and labels[mode] then
        return labels[mode]
    end
    local fallback = MODE_LABELS.en
    return fallback[mode]
end

-- ─── 1. Iniezione opzione nel pannello Dimensione font (solo CreOptions) ───
-- La scorciatoia "Font" viene inserita come prima opzione del pannello
-- (prima di font_size e font_fine_tune). NON si toccano le tabelle
-- esistenti per evitare di corrompere array condivisi.

local function injectShortcutOption()
    -- NOTA: l'etichetta è già in SHORTCUT_LABEL (calcolata a livello modulo):
    -- qui `for _, ...` oscurerebbe la `_` di gettext.
    for _, panel in ipairs(CreOptions) do
        if panel.icon == "appbar.textsize" and type(panel.options) == "table" then
            -- Guard: già iniettata?
            for _, opt in ipairs(panel.options) do
                if opt.name == SHORTCUT_NAME then
                    shortcut_option = opt
                    return true
                end
            end

            -- Posiziona la scorciatoia in prima posizione, sopra le dimensioni preimpostate.
            local insert_at = 1

            -- values omesso → niente ConfigChange, niente salvataggio in configurable.
            -- current_func restituisce sempre 0 = args[1] → current_item = 1, come
            -- prima: è solo lo stato "selezionato" (nessuna linea viene disegnata,
            -- vedi postProcessShortcutRow). args = {0} serve a current_func
            -- (l'hold non passa più da onMakeDefault: vedi postProcessShortcutRow).
            local shortcut = {
                name = SHORTCUT_NAME,
                -- name_text omesso: solo l'etichetta, senza label a sinistra.
                -- Solo placeholder: l'hook di update riscrive item_text in
                -- "CARATTERE: Lora" (etichetta tradotta in maiuscolo + nome font).
                item_text = { SHORTCUT_LABEL_UPPER },
                item_align_center = 1.0,
                item_font_size = SHORTCUT_PREVIEW_SIZE,
                height = 18, -- riga più stretta: meno spazio vuoto sopra/sotto la scorciatoia
                spacing = 15,
                args = { 0 },
                current_func = function() return 0 end, -- current_item = 1 (invariato)
                event = "ShowFontFaceMenu",
            }
            -- Riferimento per item_font_face (font attivo del documento):
            -- aggiornato a ogni ConfigDialog:update, prima del build.
            shortcut_option = shortcut
            table.insert(panel.options, insert_at, shortcut)
            logger.info("fonts-menu-patch: scorciatoia font inserita prima di font_size (sottolineata)")
            return true
        end
    end
    logger.warn("fonts-menu-patch: pannello appbar.textsize non trovato in CreOptions")
    return false
end
injectShortcutOption()

-- ─── 1b. Font attivo del documento per la scorciatoia ──────────────────────
-- La riga "Font" nel ConfigDialog viene disegnata con lo stesso font del
-- documento, così a colpo d'occhio si vede quale carattere è attivo.
-- Risoluzione identica a quella delle righe del modale: prima si prova la
-- font_func della face_table (stesso filename/faceindex già calcolati da
-- ReaderFont), poi la risoluzione diretta crengine, infine nil → "cfont".

local function activeDocFontFace(reader_font, size)
    if not reader_font or not reader_font.font_face then
        return nil
    end
    local face_name = reader_font.font_face

    -- 1) Stessa sorgente delle righe del modale (item della face_table)
    local face_table = reader_font.face_table
    if face_table then
        for _, item in ipairs(face_table) do
            if item.menu_item_id == face_name then
                -- nil se l'anteprima con il font è disattivata in lettura
                local face = item.font_func and item.font_func(size)
                if face then return face end
                break
            end
        end
    end

    -- 2) Fallback: filename + faceindex direttamente da crengine
    local cre = require("document/credocument"):engineInit()
    local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name)
    if not font_filename then
        -- Solo italico/cursive: stesso tentativo fatto da ReaderFont
        font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true)
    end
    if font_filename then
        return Font:getFace(font_filename, size, font_faceindex)
    end

    -- 3) Font non risolvibile (o getFace fallito) → nil: niente item_font_face
    --    → ConfigDialog usa "cfont" come prima della patch.
    return nil
end

-- Testo della scorciatoia: "CARATTERE: Lora" (o "FONT: Lora" in inglese).
-- Etichetta tradotta in maiuscolo + ":" + nome ORIGINALE del font attivo
-- (reader_font.font_face, stessa sorgente della voce di menù "Font: %1").
-- Testo e stile arrivano dallo stesso TextWidget → tutto in stile del font.
local function shortcutLabelText(reader_font)
    local face_name = reader_font and reader_font.font_face
    if face_name and face_name ~= "" then
        return SHORTCUT_LABEL_UPPER .. " " .. face_name
    end
    -- Nome non disponibile (caso di fatto irraggiungibile): solo l'etichetta
    return SHORTCUT_LABEL_UPPER
end

-- Aggiorna la scorciatoia "Font" nel ConfigDialog sottostante dopo un cambio
-- font dal modale: stessa coppia update + setDirty di ConfigDialog:onConfigChoose.
local function refreshShortcutFontRow(reader_font)
    local reader_config = reader_font and reader_font.ui and reader_font.ui.config
    local config_dialog = reader_config and reader_config.config_dialog
    if not config_dialog or not config_dialog.dialog_frame then return end
    -- Difesa da un riferimento rimasto indietro dopo una chiusura non pulita
    if not UIManager:isSubwidgetShown(config_dialog) then return end
    config_dialog:update()
    UIManager:setDirty(config_dialog, function()
        return "ui", config_dialog.dialog_frame.dimen
    end)
end


-- ─── 1c. Post-processo della riga scorciatoia (dopo ogni update) ────────────
-- 1) niente sottolineatura (linesize = 0, altezza contenitore invariata)
-- 2) ConfigDialog usa CenterContainer per gli item → la riga finisce al centro:
--    sostituiamo il container con LeftContainer (stessa dimen → solo paint).
-- 3) LONG-PRESS sulla riga → modale di scelta della modalità (sostituisce il
--    ConfirmBox "imposta come predefinito", che qui proponeva uno 0 senza
--    senso): l'override è sull'istanza dell'OptionTextItem (il dispatch usa
--    self[event.handler], vedi eventlistener.lua), flag per non ripeterlo.

local function postProcessShortcutRow(config_panel)
    local config_option = config_panel and config_panel[1]
    local vertical_group = config_option and config_option[1]
    if not vertical_group then return end

    for _, horizontal_group in ipairs(vertical_group) do
        -- Cerca la riga che contiene il nostro item (l'OptionTextItem)
        local found_widget = nil
        local function findShortcut(w)
            if found_widget or type(w) ~= "table" then return end
            if w.name == SHORTCUT_NAME then
                found_widget = w
                return
            end
            for _, child in ipairs(w) do
                findShortcut(child)
                if found_widget then return end
            end
        end
        findShortcut(horizontal_group)
        if not found_widget then goto continue end

        -- Hold → scelta della modalità (una sola volta per istanza)
        if not found_widget.__fonts_menu_hold then
            found_widget.onHoldSelect = function()
                showModeChooser()
                return true -- evento consumato: niente propagazione sotto
            end
            found_widget.__fonts_menu_hold = true
        end

        -- Rimuove la sottolineatura: compensando il padding con linesize/2
        -- getSize() resta identico (content.h + 2p + L), mentre
        -- paintRect(h = 0) non disegna nulla → niente linea sui descrittori.
        local underline = found_widget.underline_container
        if underline and underline.linesize ~= 0 then
            underline.padding = underline.padding + underline.linesize / 2
            underline.linesize = 0
        end

        -- Senza name_text: horizontal_group[1] è il CenterContainer della riga
        local center = horizontal_group[1]
        if not center or not center.dimen then goto continue end
        -- Già applicato?
        if center.__fonts_menu_left then goto continue end

        horizontal_group[1] = LeftContainer:new{
            dimen = center.dimen,
            FrameContainer:new{
                padding = 0,
                padding_left = Size.padding.fullscreen,
                bordersize = 0,
                center[1], -- option_items_group
            },
        }
        horizontal_group[1].__fonts_menu_left = true
        ::continue::
    end
end

-- Hook: applica dopo ogni ridisegno del ConfigDialog.
-- IMPORTANTE: tutte le varianti 2-fonts-menu*.lua nella stessa cartella
-- vengono caricate (ordine naturale: alternative → unified → plain) e la
-- prima che arriva installa il suo hook e imposta _fonts_menu_patch.
-- Noi usiamo un flag NOSTRO: se l'hook di un'altra variante è già lì, lo
-- usiamo come raw_update (il loro post-process è idempotente: flag
-- __fonts_menu_left e linesize già a 0) e ci mettiamo SOPRA, così il
-- long-press e la modalità salvata funzionano comunque. Poi impostiamo
-- anche il flag condiviso, così le varianti successive non installano il
-- loro hook.
local had_foreign_hook = ConfigDialog._fonts_menu_patch == true
if not ConfigDialog._fonts_menu_unified_patch then
    local raw_update = ConfigDialog.update -- hook di un'altra variante o originale
    function ConfigDialog:update()
        -- Font attivo del documento per la scorciatoia "Font": stile e testo
        -- ("CARATTERE: Lora") vanno assegnati PRIMA del build, perché
        -- ConfigOption:init legge item_font_face/item_text durante l'update
        -- (FontFaceObj a size 20 → pass-through in Font:getFace).
        -- Solo i pannelli CRE: con KoptOptions (PDF) la scorciatoia non c'è.
        if shortcut_option and self.config_options == CreOptions then
            local reader_font = self.ui and self.ui.font
            shortcut_option.item_font_face = activeDocFontFace(reader_font,
                SHORTCUT_PREVIEW_SIZE)
            shortcut_option.item_text = { shortcutLabelText(reader_font) }
        end
        raw_update(self)
        if self.config_panel then
            postProcessShortcutRow(self.config_panel)
        end
    end
    ConfigDialog._fonts_menu_unified_patch = true
    ConfigDialog._fonts_menu_patch = true -- le varianti successive saltano il loro hook
    logger.info("fonts-menu-patch: hook ConfigDialog:update installato"
        .. (had_foreign_hook and " (sopra quello di un'altra variante)" or "")
        .. " (font attivo, no sottolineatura, left-align, long-press)")
end

-- ─── 2. Modale font sopra il ConfigDialog ──────────────────────────────────
-- Evento "ShowFontFaceMenu" → ReaderFont:onShowFontFaceMenu
-- Apre ButtonDialog con elenco font; ConfigDialog resta aperto sotto.
-- Due modalità, scelta con getFontMenuMode():
--   floating: larghezza 80%, header fisso |Font  Close| fuori dallo scroll
--   bottom:   ancorata in basso a tutta larghezza, niente header
--             (chiudere = tap fuori o Back)
-- Tap font = onSetFont immediato.
-- Ogni riga mostra il nome del font renderizzato con se stesso (anteprima).

-- Font:getFace: se riceve già una FontFaceObj:
--   - stessa size (o nil) → pass-through (niente lookup/scaling, face_index intatto)
--   - size diversa → ricrea (caso troncamento Button: new_size -= 1)
if not Font._fonts_menu_getface_patch then
    local raw_getFace = Font.getFace
    function Font:getFace(font, size, faceindex)
        if type(font) == "table" and font.ftsize then
            if not size or size == font.orig_size then
                return font
            end
            if faceindex == nil then
                local fi = font.hash and font.hash:match("/(%d+)$")
                if fi then faceindex = tonumber(fi) end
            end
            return raw_getFace(self, font.orig_font, size, faceindex)
        end
        return raw_getFace(self, font, size, faceindex)
    end
    Font._fonts_menu_getface_patch = true
    logger.info("fonts-menu-patch: Font:getFace patchato (FontFaceObj pass-through)")
end

-- Header fisso in alto (solo modalità floating): titolo a sinistra, "Close"
-- a destra (tradotti con gettext → nella lingua impostata sul dispositivo).
-- Va reinserito dopo ogni reinit() del ButtonDialog.
-- Altezza = altezza del TextBoxWidget originale del titolo, così
-- title_group_height / top_to_content_offset / max_height calcolati
-- in ButtonDialog:init restano validi (nessun ricallcolo layout).
local function applyFontsHeader(dialog)
    if not dialog or not dialog.title_group or not dialog.title_group_width then
        return
    end
    local width = dialog.title_group_width

    local content = dialog.title_group[1] -- VerticalGroup del titolo
    if not content then return end

    -- Altezza originale del TextBoxWidget del titolo (prima di clear)
    local target_h
    if content[1] and content[1].getSize then
        target_h = content[1]:getSize().h
    end

    local fonts_label = TextWidget:new{
        text = _("Font"), -- stesso msgid della riga nel ConfigDialog
        face = Font:getFace("infofont"),
    }
    local natural_h = fonts_label:getSize().h
    local h = target_h or natural_h

    local close_btn = Button:new{
        text = _("Close"),
        bordersize = 0,
        margin = 0,
        padding = 0,
        padding_v = 0, -- nessun padding verticale → altezza = height esatto
        padding_h = Size.padding.button,
        height = h, -- altezza fissa = header (label_container = reference_height)
        text_font_face = "infofont",
        text_font_size = 20,
        text_font_bold = false,
        show_parent = dialog,
        callback = function()
            if dialog.movable then
                dialog.movable:resetEventState()
            end
            dialog:onClose() -- chiama tap_close_callback (se imposto) e UIManager:close
        end,
    }
    close_btn.overlap_align = "right"

    -- Su schermi stretti il pulsante Close (es. de "Schließen") può sforare:
    -- il titolo viene troncato con "…" invece di finirci sotto.
    -- Guard su spazio non positivo (niente max_width negativo).
    local label_max_width = width - close_btn:getSize().w - Size.padding.default
    if label_max_width > 0 then
        fonts_label:setMaxWidth(label_max_width)
    end

    -- Centra verticalmente il titolo se l'header è più alto del label;
    -- LeftContainer allinea a sinistra (CenterContainer lo sposterebbe al centro)
    local label_widget = fonts_label
    if h > natural_h then
        label_widget = LeftContainer:new{
            dimen = Geom:new{ w = width, h = h },
            fonts_label,
        }
    end

    local header = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        label_widget, -- default: left
        close_btn,    -- overlap_align = right
    }

    content:clear() -- free() + rimuove figli (niente leak)
    table.insert(content, header)
end

-- ButtonDialog ancorato in basso e a tutta larghezza dello schermo
-- (solo modalità "bottom").
-- ButtonDialog:init() riscrive self[1] con un CenterContainer, e reinit()
-- richiama init(): l'override va quindi fatto sull'init, così la modale
-- resta in basso anche dopo la scelta di un font (reinit del ✓).
local BottomButtonDialog = ButtonDialog:extend{}

function BottomButtonDialog:init()
    ButtonDialog.init(self)
    -- self[1] è il CenterContainer creato da ButtonDialog; suo figlio
    -- è il MovableContainer (self.movable) da riposizionare.
    local movable = self[1] and self[1][1]
    if movable then
        self[1] = BottomContainer:new{
            dimen = Screen:getSize(),
            movable,
        }
    end
end

-- Costruzione dell'elenco font nella modalità attiva.
-- Tutto il codice delle righe è UNICO: cambia solo il contenitore finale.
local function showFontList(reader_font)
    -- Single-instance: chiudi eventuale modale già aperta
    if active_font_dialog then
        local old = active_font_dialog
        active_font_dialog = nil
        old:onClose()
    end

    -- Se face_table esiste, NON rifare setupFaceMenuTable:
    -- con "sort by recently selected" rimetterebbe il font
    -- scelto in testa. needs_refresh viene ignorato di proposito
    -- per tenere l'ordine stabile.
    if not reader_font.face_table then
        reader_font:setupFaceMenuTable()
    end

    -- Modalità scelta (letta una volta per apertura, chiusura compresa)
    local floating = getFontMenuMode() == MODE_FLOATING
    logger.info("fonts-menu-patch: elenco font aperto (modalità "
        .. getFontMenuMode() .. ", " .. (floating and "finestra libera" or "finestra in basso") .. ")")

    local dialog
    local buttons = {}

    -- Ordine stabile: cattura l'ordine (id) la prima volta;
    -- riusa sempre quello, anche se face_table viene riordinata.
    if not reader_font._fonts_menu_order then
        reader_font._fonts_menu_order = {}
        for i = 3, #reader_font.face_table do
            local item = reader_font.face_table[i]
            if item.menu_item_id then
                table.insert(reader_font._fonts_menu_order, item.menu_item_id)
            end
        end
    end
    local ordered_items = {}
    local by_id = {}
    for i = 3, #reader_font.face_table do
        local item = reader_font.face_table[i]
        if item.menu_item_id then
            by_id[item.menu_item_id] = item
        end
    end
    local seen = {}
    for _, id in ipairs(reader_font._fonts_menu_order) do
        if by_id[id] then
            table.insert(ordered_items, by_id[id])
            seen[id] = true
        end
    end
    -- Font nuovi (non in snapshot) → in coda
    for i = 3, #reader_font.face_table do
        local item = reader_font.face_table[i]
        if item.menu_item_id and not seen[item.menu_item_id] then
            table.insert(ordered_items, item)
        end
    end

    -- Anteprima: stessa size del menù TouchMenu; altezza fissa
    -- così righe con metriche diverse restano uniformi.
    -- + Size.padding.default: margine verticale per font alti
    -- (evita clipping di glyph con ascender/descender estremi).
    local PREVIEW_SIZE = 20
    local ref_probe = TextWidget:new{
        text = "Ag",
        face = Font:getFace("infofont", PREVIEW_SIZE),
    }
    local row_height = ref_probe:getSize().h + Size.padding.default
    ref_probe:free()

    for _, item in ipairs(ordered_items) do
        local text = item.text_func and item.text_func() or item.text
        -- FontFaceObj del documento (nil se opzione disattivata
        -- o font non risolvibile → fallback font UI di default)
        local preview_face = nil
        if item.font_func then
            preview_face = item.font_func(PREVIEW_SIZE)
        end
        table.insert(buttons, {{
            text = text,
            font_face = preview_face, -- FontFaceObj o nil
            font_size = PREVIEW_SIZE, -- usato solo se face == nil
            font_bold = false,        -- anteprima fedele, non bold
            height = row_height,      -- righe allineate
            align = "left",
            avoid_text_truncation = false, -- niente loop resize su nomi lunghi
            checked_func = item.checked_func, -- ✓ sul font corrente
            callback = function()
                if item.callback then
                    item.callback() -- onSetFont + recently selected
                end
                -- Aggiorna ✓ ma MANTIENI lo scroll dove stava
                if dialog then
                    local offset = dialog:getScrolledOffset()
                    dialog:reinit()
                    -- Modalità floating: l'header va reinserito dopo ogni
                    -- reinit (che ricrea title_group). In modalità bottom
                    -- l'override di init mantiene già l'ancoraggio in basso.
                    if floating then
                        applyFontsHeader(dialog)
                    end
                    if offset then
                        dialog:setScrolledOffset(offset)
                    end
                    UIManager:setDirty(dialog, "ui")
                end
                -- La scorciatoia "Font" nel ConfigDialog sottostante
                -- deve mostrare subito il nuovo carattere attivo
                refreshShortcutFontRow(reader_font)
            end,
            hold_callback = item.hold_callback and function()
                item.hold_callback(nil) -- makeDefault (senza TouchMenu)
            end or nil,
        }})
    end

    if floating then
        dialog = ButtonDialog:new{
            title = _("Font"), -- placeholder: sostituito da applyFontsHeader
            buttons = buttons, -- solo font + scroll; Close è nell'header
            rows_per_page = 6,
            width_factor = 0.8,
            dismissable = true, -- tap fuori chiude solo il modale
        }
    else
        dialog = BottomButtonDialog:new{
            buttons = buttons, -- solo elenco font + scroll (niente header)
            rows_per_page = 6,
            -- Larghezza bordo a bordo, adattata allo schermo del device.
            -- ButtonDialog aggiunge la larghezza della scrollbar FUORI da
            -- self.width (scontainer/separator = buttontable + scrollbar):
            -- la sottraiamo così il bordo destro resta sullo schermo.
            -- (Se la lista non scorre, il pannello è più stretto di quel
            -- valore: ~9 px per lato, margine invisibile.)
            width = math.floor(Screen:getWidth() - ScrollableContainer:getScrollbarWidth()),
            dismissable = true, -- tap fuori (o Back) chiude solo il modale
        }
    end
    active_font_dialog = dialog
    -- Pulizia single-instance su OGNI percorso di chiusura:
    -- onClose, back key, tap fuori, UIManager:close(esterno).
    -- UIManager:close invia sempre CloseWidget → onCloseWidget.
    local raw_onCloseWidget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        if active_font_dialog == dialog then
            active_font_dialog = nil
        end
        if raw_onCloseWidget then
            return raw_onCloseWidget(self, ...)
        end
    end
    if floating then
        applyFontsHeader(dialog)
    end
    UIManager:show(dialog)
end

-- Handler dell'elenco font: installato SEMPRE con un flag NOSTRO.
-- Se un'altra variante (2-fonts-menu-alternative.lua, caricata prima per
-- ordine naturale) ha già installato la sua versione, viene SOSTITUITA:
-- la loro ignora la modalità salvata. Le varianti caricate DOPO di noi
-- vedono la nostra funzione e saltano la loro.
if not ReaderFont._fonts_menu_unified_handler then
    local replaced_other = ReaderFont.onShowFontFaceMenu ~= nil
    function ReaderFont:onShowFontFaceMenu()
        -- Catturato qui: dentro i callback serve per aggiornare la riga
        -- "Font" del ConfigDialog con il font appena scelto.
        local reader_font = self
        -- Deferred: lascia finire onConfigChoose (update + repaint del
        -- ConfigDialog) prima di sovrapporre la modale.
        -- nextTick scatta una volta sola al prossimo giro del loop:
        -- nessuna coda/ timer resta appeso dopo l'apertura.
        UIManager:nextTick(function()
            showFontList(reader_font)
        end)

        return true -- evento consumato
    end
    ReaderFont._fonts_menu_unified_handler = true
    logger.info("fonts-menu-patch: ReaderFont:onShowFontFaceMenu installato"
        .. (replaced_other and " (variante precedente sostituita)" or " (modale)"))
end

-- ─── 3. Modale di scelta della modalità (long-press sulla scorciatoia) ─────
-- Piccolo ButtonDialog con due voci (✓ su quella corrente) e SENZA header
-- (nessun titolo "Font": solo le due righe); tap → salva la
-- scelta in G_reader_settings e chiude. Crea widget solo per la durata del
-- modale: alla chiusura UIManager:close → CloseWidget → free() sui figli,
-- e active_mode_dialog viene azzerato (nessun riferimento residuo).

showModeChooser = function()
    -- Single-instance
    if active_mode_dialog then
        local old = active_mode_dialog
        active_mode_dialog = nil
        old:onClose()
    end

    local current = getFontMenuMode()
    -- Istanza corrente: catturata per valore nei callback, così la chiusura
    -- non dipende dallo stato di active_mode_dialog.
    local chooser

    -- NIENTE checked_func su questi pulsanti: Button:onTapSelectButton,
    -- dopo il callback, esegue label_widget:setText() + Button:refresh(),
    -- che ridisega il pulsante DENTRO il framebuffer (UIManager:widgetRepaint)
    -- e accoda un refresh "fast" su quella regione. Con il modale già chiuso
    -- in callback, quel disegno resta in sovraimpressione sul testo del libro
    -- (testo fantasma "Finestra in basso/Libera"). Il ✓ è quindi nel testo.
    local function makeButton(mode)
        local label = modeLabel(mode)
        if current == mode then
            label = label .. MODE_CHECKMARK
        end
        return {
            text = label,
            callback = function()
                -- Chiudi PRIMA di salvare: anche se il salvataggio fallisse,
                -- il modale non può restare bloccato sullo schermo.
                local dlg = chooser
                if dlg then
                    chooser = nil
                    if active_mode_dialog == dlg then
                        active_mode_dialog = nil
                    end
                    dlg:onClose()
                end
                setFontMenuMode(mode)
                logger.info("fonts-menu-patch: modalità elenco font salvata → " .. mode)
            end,
        }
    end

    chooser = ButtonDialog:new{
        -- NIENTE title: ButtonDialog, senza title né _added_widgets, usa
        -- VerticalSpan per title_group e separator (title_group_height = 0):
        -- spariscono il riquadro "Font" e la riga separatrice, restando
        -- solo le due voci. (reinit() è sicuro: title_group[1] = nil.)
        buttons = {
            { makeButton(MODE_FLOATING) },
            { makeButton(MODE_BOTTOM) },
        },
        rows_per_page = 2, -- entrambe le voci sempre visibili (niente scroll)
        width_factor = 0.7, -- compatto: due sole righe corte
        dismissable = true, -- tap fuori (o Back) chiude senza salvare
    }
    active_mode_dialog = chooser
    -- Pulizia single-instance su ogni percorso di chiusura
    local raw_onCloseWidget = chooser.onCloseWidget
    function chooser:onCloseWidget(...)
        if active_mode_dialog == chooser then
            active_mode_dialog = nil
        end
        if raw_onCloseWidget then
            return raw_onCloseWidget(self, ...)
        end
    end
    UIManager:show(chooser)
end

logger.info("fonts-menu-patch: modalità elenco font (default " .. getFontMenuMode() .. "), long-press sulla scorciatoia per cambiarla")
