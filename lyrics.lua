local inFileName, outFileName = ...

local FILE = io.open(inFileName or "", "r")
if not FILE then
    FILE = io.stdin
end

local LOG = io.open("lyricsLogfile.txt", "w+")
LOG:write(os.date() .. "\n")

local OUTFILE = io.open(outFileName or "", "w+")
if not OUTFILE then
    OUTFILE = io.stdout
end

local s = FILE:read("*a")

local escapedStuff = {}
local musicExpressions = {}

local allNoteNames = {
    nederlands = {
        search = "[a-gq][eis]?[es]?[eis]?s?",
        notes = {
            "feses", "ceses", "geses", "deses", "aeses", "eeses", "beses", -- double flats
            "fes", "ces", "ges", "des", "aes", "ees", "bes",
            "f", "c", "g", "d", "a", "e", "b",
            "fis", "cis", "gis", "dis", "ais", "eis", "bis",
            "fisis", "cisis", "gisis", "disis", "aisis", "eisis", "bisis",
            "as", "es", "ases", "eses", "q",      
        }
    },

}

local noteNames, noteSearch

do
    local language = s:match("\\language%s+%\"(%l+)%\"") or "nederlands"
    if allNoteNames[language] then
        noteNames = allNoteNames[language].notes
        noteSearch = "[^%a%\\](" .. allNoteNames[language].search .. ")"
    else
        LOG:write("Language \"" .. language .. "\" not supported!\n")
        return
    end
    for i = 1, #noteNames do
        noteNames[noteNames[i]] = true
        noteNames[i] = nil
    end
end




local preSubstitutions = {
    "%\\%\"", -- quotes inside quotes
    "%\"[^%\"]*%\"", -- quoted strings: "..."
    "[^%%]%%%{.-%%%}", -- long commments
    "%%[^\n]*\n", -- short comments
    -- footnotes are included because they seem to choke the parser
    -- the footnote is assumed to include \markup (bad assumption),
    -- but my footnotes always do because I want more space above and below them
    "%\\footnote.-%\\markup%s*%b{}",
    "%#[^\n]*\n", -- Scheme expressions
    "%\\key%s+%l+", -- key indications
    "%*?%d+%/%d+", -- fractions
}

local substitution = 0
local escChar = "Z"
while s:match(escChar .. "%d+" .. escChar) do
    escChar = string.char((string.byte(escChar)) - 1)   
end

local function DoSubstitution(s, searchString)
    s = s:gsub(searchString,
    function(w)
        local subs = escapedStuff[w]
        if subs then
            return subs
        else
            substitution = substitution + 1
            local code = escChar .. substitution .. escChar
            escapedStuff[w] = code
            escapedStuff[code] = w
            return code
        end
    end)
    return s
end

for _, searchString in ipairs(preSubstitutions) do
    s = DoSubstitution(s, searchString)
end
LOG:write(s)

local searchStrings = {
    note = "[^%\\%a](%l+)",
    melisma = ".(\\melisma)",
    melismaEnd = ".(\\melismaEnd)",
    slurStart = ".(%()",
    slurEnd = ".(%))",
    tie = ".%~",
}

local function searchForStrings(searchedString, pointer)
    local somethingFound = false
    if pointer < 2 then
        pointer = 2
    end
    local t = {}
    for ty, s in pairs(searchStrings) do
        local pos, ending = string.find(searchedString, s, pointer - 1)
        somethingFound = somethingFound or pos
        pos = pos or math.huge
        t[#t+1] = { pos = pos, ty = ty, ending = ending }
    end
    table.sort(t, function(a, b) return a.pos < b.pos end)
    return t, somethingFound
end

local slursTies = {
    ["%("] = "(",
    ["%)"] = ")",
    ["%~"] = "~",
    ["%\\melisma[^E]"] = "<",
    ["%\\melismaEnd"] = ">",
}

local function StripSpaces(s)
    return s:gsub("%s+", "")
end

for preamble, guts in s:gmatch("(%a+%s*%=%s*%\\relative%s*[a-g][eis]*[%,%']*%s*)(%b{})") do
    local key = preamble:match("%a+")
    local noteGroups = {}
    -- fold chords down
    guts = guts:gsub("%b<>", " q ")
    local pos = 1
    local start = true
    while start do
        local note, finish
        start, finish, note = guts:find(noteSearch, pos)
        if start then
            if noteNames[note] then
                noteGroups[#noteGroups+1] = { event = "N", pos = start }
            end
            pos = finish + 1
        end
    end
    for searchString, token in pairs(slursTies) do
        start = true
        pos = 1
        while start do
            local finish
            start, finish = guts:find(searchString, pos)
            if start then
                noteGroups[#noteGroups+1] = { event = token, pos = start }
                pos = finish + 1
            end
        end
    end
    table.sort(noteGroups, function(a, b) return a.pos < b.pos end)
    for i = 1, #noteGroups do
    --print(noteGroups[i].pos, noteGroups[i].event)
        noteGroups[i] = noteGroups[i].event
    end
    local tokenList = table.concat(noteGroups, " ")
    tokenList = tokenList:gsub(".%b<>", StripSpaces)
    tokenList = tokenList:gsub(".%b()", StripSpaces)
    tokenList = tokenList:gsub("N[^N]*%~", StripSpaces)
    tokenList = tokenList:gsub("%~[^N]*N", StripSpaces)
    LOG:write(tokenList) LOG:write("\n")
    local t = {}
    for w in tokenList:gmatch("%S+") do
        t[#t+1] = ( w ~= "N" )
    end
    musicExpressions[key] = t
    --print(collectgarbage("count"))
end

s = s:gsub("(%a+%s*%=%s*%\\lyricmode%s*)(%b{})",
    function(preamble, guts)
        local id = preamble:match("%a+")
        local lowerID = id:lower()
        -- find the best match
        local correspondant
        local length = #id
        local workingLength = length
        local somethingFound = false
        repeat
            local matches = {}
            for musicID, _ in pairs(musicExpressions) do
                local lowerMusicID = musicID:lower()
                for i = 1, length - workingLength + 1 do
                    if lowerMusicID:find(lowerID:sub(i, i + workingLength - 1, true)) then
                        somethingFound = true
                        matches[#matches+1] = musicID
                    end
                end
            end
            if matches[1] then
                table.sort(matches, function(a, b) return #a < #b end)
                correspondant = matches[1]
            end
            workingLength = workingLength - 1
            if workingLength < 1 then
               somethingFound = true
            end 
        until somethingFound
        if correspondant == nil then
            LOG:write("Badly formed file!\n")
        end
        local reference = musicExpressions[correspondant]

        guts = guts:sub(2, -2) -- strip leading and trailing { and }
        -- escape \xxx espressions and curly brackets
        guts = DoSubstitution(guts, "%\\%a+")
        guts = DoSubstitution(guts, "%{")
        guts = DoSubstitution(guts, "%}")
        
        guts = guts:gsub("%s%_%_", "")

        local count = 0
        guts = guts:gsub("(%S+)(%s+)(%-?%-?)(%s*)",
            function(syllable, space1, dash, space2)
                if syllable:find(escChar .. "%d+" .. escChar) then
                    local s = escapedStuff[syllable]
                    if not (s:sub(1) == "\"" and s:sub(-1) == "\"") then
                        return -- it’s not a syllable, leave it alone
                    end
                end
                count = count + 1
                if dash ~= "--" then
                    if reference[count] then
                        space2 = space1
                        space1 = " "
                        dash = "__"
                    else
                        dash = ""
                    end
                end
                return syllable .. space1 .. dash .. space2
            end
        )
        return preamble .. "{" .. guts .. "}"
    end
)

-- replace substitutions
for i = substitution, 1, -1 do -- fix everything in reverse order
    local subs = escChar .. i .. escChar
    s = s:gsub(subs, escapedStuff)
end

OUTFILE:write(s)
--collectgarbage()
--print(collectgarbage("count"))


