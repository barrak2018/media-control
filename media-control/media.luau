--!nonstrict

local SEP = string.char(31)

local dataDir = noctalia.pluginDataDir()
local textDir = nil

if dataDir then
  textDir = dataDir .. "/text"
  noctalia.mkdirAll(textDir)
end

local pythonScript = noctalia.pluginDir() and (noctalia.pluginDir() .. "/text.py") or nil

local onSurface = ""

if noctalia.getColor then
  onSurface = noctalia.getColor("on_surface") or "#E6E1E8"
end

local engine = tostring(noctalia.getConfig("text_engine") or "imagemagick")
local side = tostring(noctalia.getConfig("bar_side") or "left")
local fontName = tostring(noctalia.getConfig("font_name") or "sans-serif")
local maxLabelLen = tonumber(noctalia.getConfig("max_label_len")) or 22
local showControls = noctalia.getConfig("show_controls")
local openCommands = noctalia.getConfig("open_commands") or {}

if showControls == "false" then
  showControls = false
elseif showControls == nil then
  showControls = true
end

local status = "Stopped"
local title = ""
local artist = ""
local playerName = ""
local artUrl = ""
local artPath = nil
local playerAvailable = false

local requestInFlight = false
local coverRevision = 0
local tickCount = 0

local textPng = { title = nil, artist = nil }
local textKeys = { title = nil, artist = nil }

local render

local function log(message)
  noctalia.log("[media-control] " .. message)
end

local function hashString(value)
  local h = 5381

  for i = 1, #value do
    h = (h * 33 + string.byte(value, i)) % 4294967296
  end

  return string.format("%08x", h)
end

local function truncate(value)
  local chars = {}

  for _, codepoint in utf8.codes(value) do
    table.insert(chars, utf8.char(codepoint))
  end

  if #chars <= maxLabelLen then
    return value
  end

  local out = {}

  for i = 1, maxLabelLen - 1 do
    table.insert(out, chars[i])
  end

  table.insert(out, utf8.char(0x2026))
  return table.concat(out)
end

local function normalize(value)
  if value == nil then
    return ""
  end

  return value:gsub("[\r\n]+", " ")
end

local function renderText(role)
  if engine == "none" then
    textPng[role] = nil
    textKeys[role] = nil
    return
  end

  local value = truncate(role == "title" and title or artist)

  if value == "" then
    textPng[role] = nil
    textKeys[role] = nil
    return
  end

  local key = value .. "|" .. onSurface .. "|" .. side .. "|" .. engine

  if key == textKeys[role] then
    return
  end

  local fileName = role .. "-" .. hashString(key) .. ".png"
  local out = textDir .. "/" .. fileName

  if noctalia.fileExists(out) then
    textPng[role] = out
    textKeys[role] = key
    render()
    return
  end

  local angle = side == "left" and 90 or -90

  if engine == "pillow" then
    if pythonScript == nil then
      engine = "none"
      return
    end

    local ok = noctalia.runAsync({
      "python3",
      pythonScript,
      value,
      tostring(15),
      fontName,
      onSurface,
      tostring(angle),
      out,
    }, function(result)
      if result and result.exitCode == 0 then
        textPng[role] = out
        textKeys[role] = key
      else
        textPng[role] = nil
        textKeys[role] = nil
        log("pillow render failed: " .. (result and result.stderr or "no process"))
      end
      render()
    end)

    if not ok then
      engine = "none"
      log("pillow unavailable, text disabled")
    end
    return
  end

  if engine == "imagemagick" then
    local ok = noctalia.runAsync({
      "magick",
      "-size", "800x",
      "-background", "none",
      "-fill", onSurface,
      "-font", fontName,
      "-pointsize", "15",
      "caption:" .. value,
      "-rotate", tostring(-angle),
      out,
    }, function(result)
      if result and result.exitCode == 0 then
        textPng[role] = out
        textKeys[role] = key
      else
        textPng[role] = nil
        textKeys[role] = nil
        log("imagemagick render failed: " .. (result and result.stderr or "no process"))
      end
      render()
    end)

    if not ok then
      noctalia.runAsync({ "convert", "-version" }, function(fallback)
        if fallback and fallback.exitCode == 0 then
          noctalia.runAsync({
            "convert",
            "-size", "800x",
            "-background", "none",
            "-fill", onSurface,
            "-font", fontName,
            "-pointsize", "15",
            "caption:" .. value,
            "-rotate", tostring(-angle),
            out,
          }, function(result)
            if result and result.exitCode == 0 then
              textPng[role] = out
              textKeys[role] = key
            else
              textPng[role] = nil
              log("imagemagick render failed: " .. (result and result.stderr or "no process"))
            end
            render()
          end)
        else
          engine = "none"
          log("imagemagick unavailable, text disabled")
        end
      end)
    end
    return
  end
end

function previousTrack()
  noctalia.runAsync({ "playerctl", "previous" })
end

function togglePlayback()
  noctalia.runAsync({ "playerctl", "play-pause" })
end

function nextTrack()
  noctalia.runAsync({ "playerctl", "next" })
end

function openPlayer()
  local command = openCommands[playerName]

  if command ~= nil and command ~= "" then
    noctalia.runAsync(command)
  end
end

render = function()
  local container = barWidget.isVertical() and ui.column or ui.row

  if not playerAvailable then
    barWidget.render(container({
      gap = 4,
      align = "center",
      tooltip = "No player active",
    }, {
      ui.glyph({ name = "music", size = 18, color = "on_surface/0.6" }),
    }))
    return
  end

  local playing = status == "Playing"

  local items = {}

  if artPath ~= nil then
    table.insert(items, ui.image({
      key = "cover",
      path = artPath,
      width = 52,
      height = 52,
      radius = 10,
      fit = "cover",
      tooltip = title .. (artist ~= "" and (" - " .. artist) or ""),
      onClick = "openPlayer",
    }))
  else
    table.insert(items, ui.box({
      key = "cover",
      width = 52,
      height = 52,
      radius = 10,
      fill = "surface",
      tooltip = title .. (artist ~= "" and (" - " .. artist) or ""),
      onClick = "openPlayer",
    }, {
      ui.glyph({ name = "music", size = 20, color = "on_surface/0.5" }),
    }))
  end

  if textPng.title ~= nil then
    table.insert(items, ui.image({ key = "title", path = textPng.title }))
  end

  if textPng.artist ~= nil then
    table.insert(items, ui.image({ key = "artist", path = textPng.artist }))
  end

  if showControls then
    table.insert(items, ui.column({ key = "controls", gap = 2, align = "center" }, {
      ui.button({
        key = "previous",
        glyph = "caret-left-filled",
        glyphSize = 13,
        align = "center",
        variant = "ghost",
        width = 18,
        height = 18,
        tooltip = "Previous",
        onClick = "previousTrack",
      }),
      ui.button({
        key = "playpause",
        glyph = playing and "player-pause-filled" or "player-play-filled",
        glyphSize = 13,
        align = "center",
        variant = "ghost",
        width = 18,
        height = 18,
        tooltip = playing and "Pause" or "Play",
        onClick = "togglePlayback",
      }),
      ui.button({
        key = "next",
        glyph = "caret-right-filled",
        glyphSize = 13,
        align = "center",
        variant = "ghost",
        width = 18,
        height = 18,
        tooltip = "Next",
        onClick = "nextTrack",
      }),
    }))
  end

  if #items == 0 then
    barWidget.render(container({ gap = 4, align = "center" }, {
      ui.glyph({ name = "player-play", size = 16, color = "on_surface/0.6", onClick = "openPlayer" }),
    }))
    return
  end

  barWidget.render(container({ gap = 6, align = "center" }, items))
end

local function updateArtwork(newUrl)
  if newUrl == nil or newUrl == "" then
    artUrl = ""
    artPath = nil
    render()
    return
  end

  if newUrl == artUrl then
    return
  end

  artUrl = newUrl

  if string.sub(newUrl, 1, 7) == "file://" then
    artPath = noctalia.string.urlDecode(string.sub(newUrl, 8))
    render()
    return
  end

  if not string.match(newUrl, "^https?://") then
    artPath = nil
    render()
    return
  end

  if dataDir == nil then
    return
  end

  coverRevision = coverRevision + 1

  local revision = coverRevision
  local destination = dataDir .. "/cover-" .. tostring(revision % 2) .. ".jpg"

  noctalia.download(newUrl, destination, function(ok)
    if not ok then
      return
    end

    if revision ~= coverRevision then
      return
    end

    artPath = destination
    render()
  end)
end

local function refreshMetadata()
  if requestInFlight then
    return
  end

  requestInFlight = true

  local format =
    "{{status}}" .. SEP ..
    "{{title}}" .. SEP ..
    "{{artist}}" .. SEP ..
    "{{mpris:artUrl}}" .. SEP ..
    "{{playerName}}"

  noctalia.runAsync({ "playerctl", "metadata", "--format", format }, function(result)
    requestInFlight = false

    if result == nil or result.exitCode ~= 0 then
      playerAvailable = false
      status = "Stopped"
      title = ""
      artist = ""
      playerName = ""
      artUrl = ""
      artPath = nil
      render()
      return
    end

    playerAvailable = true

    local output = normalize(result.stdout)

    local newStatus, newTitle, newArtist, newArtUrl, newPlayerName =
      string.match(
        output,
        "^(.-)" .. SEP ..
        "(.-)" .. SEP ..
        "(.-)" .. SEP ..
        "(.-)" .. SEP ..
        "(.*)$"
      )

    if newStatus == nil then
      return
    end

    status = newStatus
    title = newTitle or ""
    artist = newArtist or ""
    playerName = newPlayerName or ""

    renderText("title")
    renderText("artist")
    render()
    updateArtwork(newArtUrl or "")
  end)
end

function update()
  noctalia.setUpdateInterval(500)

  tickCount = tickCount + 1

  if tickCount % 2 == 0 then
    refreshMetadata()
  end
end

render()
refreshMetadata()