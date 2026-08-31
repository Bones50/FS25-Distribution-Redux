-- ============================================================================
-- DistributionModWarning.lua  (Distribution Redux)
--
-- KNOWN PROBLEM MODS. Some mods do the same job as DR, or reach into the same
-- state, and the result is two mods fighting over one decision. The player is
-- not told to remove anything -- they are told WHERE TO LOOK when something
-- misbehaves, which is the whole point: a silent collision costs an evening,
-- and a named one costs a minute.
--
-- THE LIST IS DATA, EDITED HERE. Add an entry by adding a row.
--
-- EVERY ENTRY CARRIES ITS REASON, and the reason is NOT shown to the player. It
-- is here for whoever maintains this list: without it, a name on a list is
-- unfalsifiable a year from now and nobody can tell whether it still belongs.
-- The dialog names the mods and stops there -- the player's job is to decide
-- what to run, not to read a diagnosis.
--
-- MATCHED ON THE MOD'S FOLDER / ZIP NAME, never its title. The title is
-- localised and editable; the name is what g_modIsLoaded is keyed by, which is
-- the same reasoning as persisting an animal subtype by name (Animal Redux 10.4).
-- ============================================================================

DistributionModWarning = {}

DistributionModWarning.KNOWN = {
    {
        name   = "FS25_AgroLogistics",
        reason = "periodically sweeps all pallet spawns and moves them to its logistics centre, "
              .. "overriding whatever you set in Distribution Redux",
    },
    {
        name   = "FS25_ProductionStorageControl",
        reason = "changes production output modes, which collides with Distribution Redux and "
              .. "breaks both. Distribution Redux already does everything it does",
    },
    {
        name   = "FS25_MultiCropGreenhouses",
        reason = "registers a shared pallet for bulk crops that pallet cannot actually hold, which "
              .. "fills the log with spawn errors on a farm with full pallet pads",
    },
}

---Which of the known-problem mods are actually loaded, as { name, reason }.
--
-- g_modIsLoaded is the base game's own test (it uses it for exactly this kind of
-- interop check), so a mod present but DISABLED is correctly not reported -- the
-- warning is about what is running, not what is on disk.
function DistributionModWarning.detect()
    local found = {}
    if g_modIsLoaded == nil then return found end
    for _, entry in ipairs(DistributionModWarning.KNOWN) do
        if g_modIsLoaded[entry.name] then
            found[#found + 1] = entry
        end
    end
    return found
end

---The warning text: the message, then one line per offending mod with its reason.
function DistributionModWarning.buildText(found)
    local L = (SmartDistribution ~= nil and SmartDistribution.l10n) or function(_, f) return f end
    local lines = { L("dr_modwarn_body",
        "WARNING! You currently have mods activated that are known to create issues with "
     .. "Distribution Redux. You can continue, but game performance and mod performance cannot be "
     .. "guaranteed while these mods are active. To avoid this warning, quit and reload the save "
     .. "without the below mods activated:"), "" }
    for _, e in ipairs(found) do
        -- FOLDER NAME FIRST, then the display title. The folder name is what the player has to find
        -- and untick in the mod list, so it leads; the title is what they recognise, so it follows.
        -- The REASON is deliberately NOT shown -- it is kept in the table above for whoever maintains
        -- this list, not put in front of a player who only needs to know which mods to look at.
        local title = nil
        if g_modManager ~= nil and g_modManager.getModByName ~= nil then
            local ok, m = pcall(g_modManager.getModByName, g_modManager, e.name)
            if ok and m ~= nil and m.title ~= nil and m.title ~= "" then title = tostring(m.title) end
        end
        if title ~= nil and title ~= e.name then
            lines[#lines + 1] = string.format("%s  -  %s", e.name, title)
        else
            lines[#lines + 1] = e.name
        end
    end
    return table.concat(lines, "\n")
end

---Show it, once per mission load -- EVERY load, with no way to switch it off.
--
-- Deliberately not a setting. A "do not show again" is a switch to forget the collision, and the
-- collision then comes back months later as a Distribution Redux bug report. It costs one dismissal
-- per load and it is the cheapest diagnosis in the mod.
--
-- DEFERRED TO THE FIRST TICK, not shown from the load hook. The same reason
-- runOrphanCheck defers (6.19): at load time the world is still assembling and
-- the GUI is not necessarily up, and a dialog raised into a half-built screen is
-- the kind of thing that either does not appear or appears behind everything.
--
-- InfoDialog, one button. A "quit to menu" button was considered and dropped: the
-- call is not readable (InGameMenu.lua is 96% blank, Mission00 is absent, and no
-- installed mod performs a quit), and the message tells the player how to do it
-- themselves in one line. Author's call, 2026-08-29.
function DistributionModWarning.showIfNeeded()
    if DistributionModWarning._shown then return end
    DistributionModWarning._shown = true

    local found = DistributionModWarning.detect()
    if #found == 0 then return end

    local text = DistributionModWarning.buildText(found)
    -- ALWAYS log it, dialog or no dialog: the log is what gets sent to us when a player reports a
    -- problem, and it outlives a dialog nobody wrote down.
    print("[SmartDistribution] " .. text:gsub("\n", " | "))

    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        pcall(InfoDialog.show, text)
    elseif g_gui ~= nil and g_gui.showInfoDialog ~= nil then
        pcall(g_gui.showInfoDialog, g_gui, { text = text })
    end
end
