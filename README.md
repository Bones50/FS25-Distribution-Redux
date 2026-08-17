# FS25-Distribution-Redux
Replaces Farming Simulator 25's standard distribution system with a smarter, demand-driven logistics network.
Distribution Redux automatically moves resources between productions, animal husbandries, silos, and storages based on actual demand. It prioritises the nearest available source, supports automatic feed, straw, and water distribution, and gives you full control over how each output is handled!

If you need help, join the discord: https://discord.gg/nK5Q7KCbY
If you want to support my work buy me a coffee: https://ko-fi.com/bones13123

<h2><b>TO USE THE CURRENT GITHUB RELEASED VERSION</b></h2>
1) Go to releases in gituhub
2) Download the latest release (zip)
3) Copy the new zip file to your FS25 Mods folder (replace the existing one if you have a previous version already installed)
NOTE: If modhub has not yet been updated to the latest release, when in game the mod will show as requiring update. Do NOT update as it will revert to the previous modhub version.

<h2><b>TO TEST THE CURRENT GITHUB WORKING (UNRELEASED) VERSION</b></h2>
1) Go to the "Code" Option at the top right and download zip
2) Go to where the zip downloaded and unzip it.
3) Navigate through the folders until you get to the folder with 3 files and 3 folders in it.
4) Delete the readme.md file
5) Select the 2 remaining files and the 3 folders (gui, scripts, translations) and zip it back up.
6) Rename the ZIP file to FS25_Distribution_Redux.
7) Copy the new zip file to your FS25 Mods folder (replace the existing one if you have a previous version already installed)
NOTE: When in game the mod will show as requiring update. Do NOT update as it will revert to the previous modhub version.

<h2><b>TRANSLATIONS - CONTRIBUTIONS WELCOME</b></h2>

Distribution Redux uses the standard Farming Simulator localisation system, so a translation is a
pull request against one file and needs no Lua or XML knowledge beyond copy-and-edit.

How to add a language
1) Copy translations/translation_en.xml to translations/translation_xx.xml.
   Codes FS25 uses: br cs ct cz da de ea en es fc fi fr hu id it jp kr nl no pl pt ro ru sv tr uk vi
2) Translate ONLY the text="..." values. Never change a name="..." key - that is what the mod looks up.
3) Open a pull request.

Things worth knowing before you start
- A PARTIAL TRANSLATION IS FINE. Any key you leave out falls back to English, so there is no need to
  finish the file in one go and no way to break the mod by omitting something.
- Keys ending _tt are tooltips. They wrap freely, so length does not matter there.
- Keys starting dr_col_ are table column headers in fixed-width cells, and dr_btn_ are buttons sharing
  one footer bar. These are the ones to keep short: text that overruns is clipped rather than wrapped.
  The character budget is noted in a comment above each block in the file.
- The _v1, _v2, ... keys under each setting are that setting's selector options. Translate them in
  place; never reorder or drop one, because the position is what the save file records, not the label.
- An XML comment cannot contain two hyphens in a row - it is a parse error that voids the whole file.
  Several attribute VALUES do contain them, which is fine; leave those exactly as they are.

Currently translated: English. Everything else falls back to English until someone contributes it.

Coverage is now COMPLETE - every piece of player-facing text is translatable: the settings screen,
all table headers and buttons, output mode names, status words, both Advanced dialogs, and the whole
in-game User Guide. There is nothing left hardcoded.

The one thing translation_*.xml does NOT cover: the mod's STORE PAGE
The mod title and description shown in the mod list and on ModHub live in modDesc.xml, not in the
translation files. The game's mod manager reads them before the mod (and its translations) is loaded,
so they have their own built-in per-language form and cannot use translation keys:

    <description>
        <en><![CDATA[ ...English... ]]></en>
        <de><![CDATA[ ...German... ]]></de>
    </description>

If you want the store page in your language too, add an xx block there alongside the existing ones,
where xx is the same code you used for your translation file. Optional - the UI and the User Guide are
fully translated by your translation file on its own.

About the User Guide (the dr_guide_ keys)
- It is the bulk of the file: 11 topics, 230 paragraphs, about 4,900 words. It sits in its own block
  at the end, and you can translate it a paragraph at a time - anything you leave out stays English.
- Each key is one paragraph. A value starting "## ", "### " or "- " is a heading, a sub-heading or a
  bullet: that marker is STRUCTURE, not words, so keep it exactly and translate only what follows.
- Do not renumber the keys. The numbers are positions in the guide.