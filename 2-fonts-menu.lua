-- Patch: scorciatoia "SHOW FONTS" nel ConfigDialog (pannello Dimensione font)
-- Un tap su "SHOW FONTS" apre una modale ButtonDialog con l'elenco dei font
-- (stessa sorgente del menù: face_table / cre.getFontFaces).
-- Il ConfigDialog resta aperto sotto la modale.
-- Tap su un font → applica subito; "Close" → chiude solo la modale.
-- Solo documenti CRE (EPUB/TXT/...): i PDF usano KoptOptions e non
-- vengono toccati.

local CreOptions = require("ui/data/creoptions")
local ReaderFont = require("apps/reader/modules/readerfont")
local UIManager = require("ui/uimanager")
local ConfigDialog = require("ui/widget/configdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Button = require("ui/widget/button")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Size = require("ui/size")
local logger = require("logger")
local _ = require("gettext")

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

-- ─── 2. Modale font sopra il ConfigDialog ──────────────────────────────────
-- Evento "ShowFontFaceMenu" → ReaderFont:onShowFontFaceMenu
-- Apre ButtonDialog con elenco font; ConfigDialog resta aperto sotto.
-- Header fisso: |Fonts              Close| (fuori dallo scroll).
-- Tap font = onSetFont immediato.

-- Header fisso in alto: "Fonts" a sinistra, "Close" a destra (inglese).
-- Va reinserito dopo ogni reinit() del ButtonDialog.
local function applyFontsHeader(dialog)
    if not dialog or not dialog.title_group or not dialog.title_group_width then
        return
    end
    local width = dialog.title_group_width

    local fonts_label = TextWidget:new{
        text = "Fonts",
        face = Font:getFace("infofont"),
    }
    local close_btn = Button:new{
        text = "Close", -- solo testo inglese, non tradotto
        bordersize = 0,
        margin = 0,
        padding = Size.padding.buttontable,
        padding_h = Size.padding.button,
        text_font_face = "infofont",
        text_font_size = 20,
        text_font_bold = false,
        show_parent = dialog,
        callback = function()
            if dialog.movable then
                dialog.movable:resetEventState()
            end
            UIManager:close(dialog)
        end,
    }
    close_btn.overlap_align = "right"

    local h = math.max(fonts_label:getSize().h, close_btn:getSize().h)
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        fonts_label,  -- default: left
        close_btn,    -- overlap_align = right
    }

    local content = dialog.title_group[1] -- VerticalGroup del titolo
    if not content then return end
    for i = #content, 1, -1 do
        content[i] = nil
    end
    table.insert(content, header)
    if content.resetLayout then
        content:resetLayout()
    end
end

if not ReaderFont.onShowFontFaceMenu then
    function ReaderFont:onShowFontFaceMenu()
        -- Deferred: lascia finire onConfigChoose (update + repaint del
        -- ConfigDialog) prima di sovrapporre la modale.
        UIManager:nextTick(function()
            -- Stessa sorgente del menù esistente
            if not self.face_table or self.face_table.needs_refresh then
                self:setupFaceMenuTable()
            end

            local dialog
            local buttons = {}

            -- face_table: [1]=Font settings, [2]=Font-family fonts, poi i font
            for i = 3, #self.face_table do
                local item = self.face_table[i]
                if item.menu_item_id then
                    local text = item.text_func and item.text_func() or item.text
                    table.insert(buttons, {{
                        text = text,
                        checked_func = item.checked_func, -- ✓ sul font corrente
                        callback = function()
                            if item.callback then
                                item.callback() -- onSetFont + recently selected
                            end
                            -- Aggiorna marcatore + riusa header fisso
                            if dialog then
                                dialog:reinit()
                                applyFontsHeader(dialog)
                                UIManager:setDirty(dialog, "ui")
                            end
                        end,
                        hold_callback = item.hold_callback and function()
                            item.hold_callback(nil) -- makeDefault (senza TouchMenu)
                        end or nil,
                    }})
                end
            end

            dialog = ButtonDialog:new{
                title = "Fonts", -- placeholder: sostituito da applyFontsHeader
                buttons = buttons, -- solo font + scroll; Close è nell'header
                rows_per_page = 6,
                width_factor = 0.8,
                dismissable = true, -- tap fuori chiude solo il modale
            }
            applyFontsHeader(dialog)
            UIManager:show(dialog)
        end)

        return true -- evento consumato
    end
    logger.info("fonts-menu-patch: ReaderFont:onShowFontFaceMenu installato (modale)")
else
    logger.info("fonts-menu-patch: onShowFontFaceMenu già presente, patch saltata")
end
