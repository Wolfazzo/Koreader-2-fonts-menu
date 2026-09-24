-- Patch: scorciatoia "Aa" nel menù in basso (ConfigDialog)
-- Nella scheda "Dimensione font" (pannello appbar.textsize) compare la
-- scorciatoia "Aa" subito sotto la riga "Dimensione Font / diminuisci / aumenta":
-- un tap apre direttamente il pannello di scelta dei font già presente in app.
-- Solo documenti CRE (EPUB/TXT/...): i PDF usano KoptOptions e non
-- vengono toccati.

local CreOptions = require("ui/data/creoptions")
local ReaderFont = require("apps/reader/modules/readerfont")
local UIManager = require("ui/uimanager")
local ConfigDialog = require("ui/widget/configdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Size = require("ui/size")
local logger = require("logger")

local SHORTCUT_NAME = "font_face_shortcut"

-- ─── 1. Iniezione opzione nel pannello Dimensione font (solo CreOptions) ───
-- "Aa" viene inserita come opzione separata subito dopo font_fine_tune
-- (la riga "diminuisci / aumenta"). NON si toccano le tabelle esistenti
-- di font_size per evitare di corrompere array condivisi.

local function injectShortcutOption()
    for _, panel in ipairs(CreOptions) do
        if panel.icon == "appbar.textsize" and type(panel.options) == "table" then
            -- Guard: già iniettata?
            for _, opt in ipairs(panel.options) do
                if opt.name == SHORTCUT_NAME then
                    return true
                end
            end

            -- Posiziona Aa in prima posizione, sopra le dimensioni preimpostate.
            local insert_at = 1

            -- values omesso → niente ConfigChange, niente salvataggio in configurable.
            -- current_func restituisce sempre 0 = args[1]: ConfigDialog imposta
            -- current_item = 1 ad ogni ridisegno → sottolineatura nera permanente su Aa.
            -- args = {0} è necessario sia per current_func sia per onMakeDefault.
            table.insert(panel.options, insert_at, {
                name = SHORTCUT_NAME,
                -- name_text omesso: solo le lettere Aa, senza etichetta a sinistra
                item_text = { "SHOW FONTS" },
                item_align_center = 1.0,
                item_font_size = 20,
                height = 18, -- riga più stretta: meno spazio vuoto sopra/sotto Aa
                spacing = 15,
                args = { 0 },
                current_func = function() return 0 end, -- forza sottolineatura sempre visibile
                event = "ShowFontFaceMenu",
            })
            logger.info("fonts-menu-patch: scorciatoia Aa inserita prima di font_fine_tune (sottolineata)")
            return true
        end
    end
    logger.warn("fonts-menu-patch: pannello appbar.textsize non trovato in CreOptions")
    return false
end

injectShortcutOption()

-- ─── 1b. Allineamento "Aa" al bordo sinistro del pannello ─────────────────
-- ConfigDialog usa CenterContainer per gli item → "Aa" finisce al centro.
-- Dopo ogni update() sostituiamo il container della riga con LeftContainer
-- (stessa dimen → nessun resize, solo diverso paint).

local function leftAlignShortcutRow(config_panel)
    local config_option = config_panel and config_panel[1]
    local vertical_group = config_option and config_option[1]
    if not vertical_group then return end

    for _, horizontal_group in ipairs(vertical_group) do
        -- Cerca la riga che contiene il nostro item
        local found = false
        local function findShortcut(w)
            if found or type(w) ~= "table" then return end
            if w.name == SHORTCUT_NAME then
                found = true
                return
            end
            for _, child in ipairs(w) do
                findShortcut(child)
                if found then return end
            end
        end
        findShortcut(horizontal_group)
        if not found then goto continue end

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

-- Hook: applica dopo ogni ridisegno del ConfigDialog
if not ConfigDialog._fonts_menu_patch then
    local raw_update = ConfigDialog.update
    function ConfigDialog:update()
        raw_update(self)
        if self.config_panel then
            leftAlignShortcutRow(self.config_panel)
        end
    end
    ConfigDialog._fonts_menu_patch = true
    logger.info("fonts-menu-patch: hook ConfigDialog:update installato (Aa left-align)")
end

-- ─── 2. Apertura diretta della lista font dal ConfigDialog ─────────────────
-- Evento "ShowFontFaceMenu" spedito da ConfigDialog:onConfigEvent
-- → propagato a ReaderUI → ReaderFont:onShowFontFaceMenu

local function findTypesetTabIndex(menu)
    if menu.tab_item_table == nil then
        menu:setUpdateItemTable()
    end
    local tabs = menu.tab_item_table
    if not tabs then return 2 end
    for i, tab in ipairs(tabs) do
        if tab.id == "typeset" or tab.icon == "appbar.typeset" then
            return i
        end
    end
    return 2 -- fallback: typeset è di default la seconda tab
end

local function selectChangeFontItem(menu)
    local container = menu.menu_container
    if not (container and container[1]) then return end
    local touch_menu = container[1]
    local item_table = touch_menu.item_table
    if not item_table then return end
    for _, item in ipairs(item_table) do
        if item.id == "change_font" then
            -- FIX 1: verifica che onMenuSelect esista prima di chiamarlo
            if type(touch_menu.onMenuSelect) == "function" then
                touch_menu:onMenuSelect(item)
            end
            return true
        end
    end
    logger.warn("fonts-menu-patch: item change_font non trovato nel tab typeset")
    return false
end

if not ReaderFont.onShowFontFaceMenu then
    function ReaderFont:onShowFontFaceMenu()
        -- Tutto deferred: lascia finire onConfigChoose (update + repaint
        -- del ConfigDialog) prima di chiudere/sovrapporre il menù principale
        UIManager:nextTick(function()
            -- 1. Chiudi il ConfigDialog, se ancora aperto
            local config = self.ui and self.ui.config
            if config and config.config_dialog then
                -- FIX 2: verifica che closeDialog esista come funzione
                if type(config.config_dialog.closeDialog) == "function" then
                    config.config_dialog:closeDialog()
                end
            end

            local menu = self.ui and self.ui.menu
            if not menu or not menu.onShowMenu then return end

            -- Garantisci che face_table esista (di solito già costruita
            -- da setupFaceMenuTable in onReadSettings)
            if not self.face_table then
                self:setupFaceMenuTable()
            end

            -- Chiudi un eventuale menù principale già aperto
            if menu.menu_container and menu.onCloseReaderMenu then
                menu:onCloseReaderMenu()
            end

            local tab_index = findTypesetTabIndex(menu)
            menu:onShowMenu(tab_index)

            -- 2. Dopo che il TouchMenu è mostrato, apri change_font
            UIManager:nextTick(function()
                selectChangeFontItem(menu)
            end)
        end)

        return true -- evento consumato
    end
    logger.info("fonts-menu-patch: ReaderFont:onShowFontFaceMenu installato")
else
    logger.info("fonts-menu-patch: onShowFontFaceMenu già presente, patch saltata")
end
