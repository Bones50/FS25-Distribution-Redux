-- ============================================================================
-- DistributionPickDialog.lua  (Distribution Redux) -- pick one building from a list
--
-- FS25 HAS NO DROPDOWN ELEMENT, and that is established rather than assumed:
-- there is no DropDown or ComboBox anywhere in the shipped GUI source, none in
-- `guiProfiles.xml`'s 512 profiles, and not one of the 40-odd installed mods
-- declares such a tag. The base game's only list-shaped dialogs are YesNo, Info,
-- Color and MultiOption -- and MultiOption is a CYCLING selector in a dialog,
-- i.e. the very thing being replaced.
--
-- So a dropdown here is a PICKER DIALOG: the control shows the current choice and
-- opening it lists every option with a scrollbar, which is what a player means by
-- "not cycling". Built on MessageDialog like DR's four other dialogs.
--
-- DELIBERATELY GENERIC. It takes rows of `{ name, sub, icon }` and hands back an
-- INDEX, so it knows nothing about buildings and can serve the next long list
-- without being copied -- which is 6.18's trap, and the reason this is not
-- DistributionBuildingDialog.
-- ============================================================================

DistributionPickDialog = {}
local Dlg_mt = Class(DistributionPickDialog, MessageDialog)

function DistributionPickDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.rows     = {}
    self.rowIndex = 1
    self.onPick   = nil
    return self
end

---`rows[i] = { name, sub, icon }`. `onPick(index)` fires on a click, then the dialog closes.
function DistributionPickDialog:setup(title, rows, index, onPick)
    self.rows     = rows or {}
    self.rowIndex = (type(index) == "number" and index >= 1 and index <= #self.rows) and index or 1
    self.onPick   = onPick
    if self.dialogTitleElement ~= nil and title ~= nil then self.dialogTitleElement:setText(title) end
end

function DistributionPickDialog:onOpen()
    DistributionPickDialog:superClass().onOpen(self)
    if self.pickList ~= nil then
        self.pickList:setDataSource(self)
        self.pickList:setDelegate(self)
        self.pickList:reloadData()
        -- A REUSED DIALOG KEEPS ITS LIST SELECTION and `setup` has just set rowIndex from the
        -- caller; nothing reconciles the two unless this does. 5.77a records exactly that
        -- going unnoticed on the Advanced Inputs dialog until a second table made it visible.
        if self.pickList.setSelectedItem ~= nil and #self.rows > 0 then
            pcall(self.pickList.setSelectedItem, self.pickList, 1, self.rowIndex, true)
        end
    end
end

function DistributionPickDialog:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function DistributionPickDialog:populateCellForItemInSection(list, section, index, cell)
    local r = self.rows[index]
    if r == nil or cell == nil or cell.getAttribute == nil then return end
    local function setText(name, text)
        local el = cell:getAttribute(name)
        if el ~= nil and el.setText ~= nil then el:setText(text or "") end
    end
    setText("name", r.name)
    setText("sub", r.sub)
    -- CELLS ARE RECYCLED, so the icon is set on BOTH paths or a row inherits the picture of
    -- whichever row last used its slot (5.7 / 5.57).
    local ic = cell:getAttribute("icon")
    if ic ~= nil then
        if r.icon ~= nil and ic.setImageFilename ~= nil then
            ic:setImageFilename(r.icon)
            ic:setVisible(true)
        else
            ic:setVisible(false)
        end
    end
end

---A CLICK, not a selection change: clicking the row the list is already on raises no
-- selection event at all (6.29), and on a reopened dialog that row is exactly the one the
-- player most often wants to confirm.
function DistributionPickDialog:onPickClick(list, section, index)
    if type(index) ~= "number" then index = self.rowIndex end
    self.rowIndex = index
    local fn = self.onPick
    self:close()
    if fn ~= nil then pcall(fn, index) end
end

function DistributionPickDialog:onPickSelectionChanged(list, section, index)
    if type(index) == "number" then self.rowIndex = index end
end

function DistributionPickDialog:onClickBack()
    self:close()
    return false
end
