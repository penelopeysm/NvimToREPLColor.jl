module NvimToREPLColor

# nvim2juliarepl.jl: convert a Neovim colorscheme into a Julia REPL theme.
#
# Queries a headless Neovim for the resolved colors of a set of treesitter
# highlight groups, maps them onto the `julia_*` faces used by Julia 1.13+ for
# REPL syntax highlighting, and writes a StyledStrings `faces.toml`.
#
# Usage (after `pkg> app develop .` or `pkg> app add`):
#   nvim2juliarepl                    # uses current nvim config
#   nvim2juliarepl --output path.toml # custom output path
#   nvim2juliarepl --colorscheme foo  # override colorscheme name
#   nvim2juliarepl --force            # overwrite an existing faces.toml
#   nvim2juliarepl --rainbow          # color-cycle brackets by nesting depth
#
# Requires `nvim` (0.9+) on PATH. No Julia package dependencies.

# ---------------------------------------------------------------------------
# 1. Mapping table: Julia REPL face => how to derive it
# ---------------------------------------------------------------------------

# A face is derived either by querying one or more nvim highlight groups
# (the first group with a foreground color wins), or by inheriting from other
# Julia faces, or both. `extra` holds fixed TOML keys to always emit.
struct FaceSpec
    name::String
    groups::Vector{String}          # nvim highlight groups to try, in order
    inherit::Vector{String}         # Julia faces to inherit from
    fallback_inherit::Vector{String} # inherit from these if no group had a distinct color
    distinct_from::Union{Nothing,String} # a group's color only counts if it differs from this group
    extra::Vector{Pair{String,Any}}  # fixed extra keys, e.g. "weight" => "bold"
end

FaceSpec(name; groups=String[], inherit=String[], fallback_inherit=String[],
         distinct_from=nothing, extra=Pair{String,Any}[]) =
    FaceSpec(name, groups, inherit, fallback_inherit, distinct_from, extra)

# Debatable choices are noted inline; edit this table to change the mapping.
const FACE_SPECS = FaceSpec[
    FaceSpec("julia_macro"; groups=["@function.macro"]),
    FaceSpec("julia_symbol"; groups=["@string.special.symbol"]),
    FaceSpec("julia_singleton_identifier"; inherit=["julia_symbol"]),
    FaceSpec("julia_type"; groups=["@type"]),
    # `::` — could arguably use @type instead, but the type name already gets julia_type
    FaceSpec("julia_typedec"; groups=["@operator"]),
    FaceSpec("julia_comment"; groups=["@comment"]),
    FaceSpec("julia_string"; groups=["@string"]),
    # Julia default: inherits from julia_string. Only emit a color if the theme
    # distinguishes regexes; otherwise emit the inherit.
    # @string.regexp is the current capture name; @string.regex is the pre-2024 name
    FaceSpec("julia_regex"; groups=["@string.regexp", "@string.regex"], distinct_from="@string",
        fallback_inherit=["julia_string"]),
    # Julia default keeps `inherit = julia_string` alongside its own foreground
    FaceSpec("julia_backslash_literal"; groups=["@string.escape"], inherit=["julia_string"]),
    # Quote marks are the same color as the string body in most themes
    FaceSpec("julia_string_delim"; groups=["@string"]),
    FaceSpec("julia_cmd"; inherit=["julia_string"]),
    FaceSpec("julia_cmd_delim"; inherit=["julia_string_delim"]),
    FaceSpec("julia_char"; inherit=["julia_string"]),
    FaceSpec("julia_char_delim"; inherit=["julia_string_delim"]),
    FaceSpec("julia_number"; groups=["@number"]),
    FaceSpec("julia_bool"; groups=["@boolean"], distinct_from="@number",
        fallback_inherit=["julia_number"]),
    FaceSpec("julia_funcall"; groups=["@function.call"]),
    FaceSpec("julia_funcdef"; groups=["@function"]),
    # No dedicated treesitter capture for `.+` etc.; Julia default is bold
    FaceSpec("julia_broadcast"; groups=["@operator"], extra=["weight" => "bold"]),
    # Julia uses this face for `&&`, `||` and `ccall`. Treesitter puts `&&`/`||`
    # under @keyword.operator, so prefer that; the price is `ccall` gets the same color.
    FaceSpec("julia_builtin"; groups=["@keyword.operator"]),
    FaceSpec("julia_operator"; groups=["@operator"]),
    FaceSpec("julia_comparator"; inherit=["julia_operator"]),
    # `=` — same as operator; some themes might want this distinct
    FaceSpec("julia_assignment"; groups=["@operator"]),
    # `+=` etc.; Julia default inherits from julia_assignment
    FaceSpec("julia_opassignment"; inherit=["julia_assignment"]),
    FaceSpec("julia_keyword"; groups=["@keyword"]),
    # Unstyled in the Julia default, so any color here is a real change
    FaceSpec("julia_parentheses"; groups=["@punctuation.bracket"]),
    FaceSpec("julia_unpaired_parentheses"; inherit=["julia_error", "julia_parentheses"]),
    # Not a treesitter group; typically a red background
    FaceSpec("julia_error"; groups=["Error"]),
]

# Groups used as a fallback palette for rainbow brackets when no rainbow
# plugin highlight groups are defined. Order matters: earlier = preferred.
const RAINBOW_FALLBACK_GROUPS = ["@keyword", "@string", "@number", "@function", "@type",
    "@function.macro", "@constant", "@operator"]

const RAINBOW_PLUGIN_GROUPS = ["rainbowcol$i" for i in 1:7]

# ---------------------------------------------------------------------------
# 2. Query Neovim
# ---------------------------------------------------------------------------

struct Hl
    fg::Union{Nothing,String}
    bg::Union{Nothing,String}
    attrs::Set{String}   # subset of bold, italic, underline, strikethrough, reverse
end
Base.:(==)(a::Hl, b::Hl) = a.fg == b.fg && a.bg == b.bg && a.attrs == b.attrs

# Environment variables used to pass data into the headless nvim session
const ENV_GROUPS = "NVIM2JULIAREPL_GROUPS"  # comma-separated highlight group names
const ENV_OUT = "NVIM2JULIAREPL_OUT"        # path nvim should write its results to
const ENV_COLORSCHEME = "NVIM2JULIAREPL_COLORSCHEME"  # optional colorscheme to activate first

const NVIM_LUA = """
-- Switch colorscheme from Lua rather than via `-c colorscheme NAME`: a failed
-- `-c` command only prints an error and nvim carries on with exit code 0, so
-- we would silently query the config's own colorscheme instead.
local cs = vim.env.$ENV_COLORSCHEME
if cs and cs ~= "" then
  local ok, err = pcall(vim.cmd.colorscheme, cs)
  if not ok then
    io.stderr:write("error: " .. tostring(err) .. "\\n")
    vim.cmd("cquit! 1")
  end
end
local groups = vim.fn.split(vim.env.$ENV_GROUPS, ",")
local out = {}
for _, name in ipairs(groups) do
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or hl == nil then hl = {} end
  local function hex(v) return v and string.format("#%06x", v) or "NONE" end
  local attrs = {}
  for _, a in ipairs({ "bold", "italic", "underline", "strikethrough", "reverse" }) do
    if hl[a] then table.insert(attrs, a) end
  end
  table.insert(out, table.concat({ name, hex(hl.fg), hex(hl.bg),
    #attrs > 0 and table.concat(attrs, ",") or "NONE" }, "\t"))
end
local f = io.open(vim.env.$ENV_OUT, "w")
f:write(table.concat(out, "\\n"), "\\n")
f:close()
vim.cmd("qall!")
"""

function query_nvim(groups::Vector{String}; colorscheme::Union{Nothing,String}=nothing)
    mktempdir() do dir
        luafile = joinpath(dir, "query.lua")
        outfile = joinpath(dir, "out.tsv")
        write(luafile, NVIM_LUA)
        # Note: headless nvim still loads the user's init.lua/init.vim, so the
        # active colorscheme and treesitter setup are in effect.
        args = String["nvim", "--headless", "-c", "luafile $luafile"]
        env = copy(ENV)
        env[ENV_GROUPS] = join(groups, ",")
        env[ENV_OUT] = outfile
        colorscheme === nothing || (env[ENV_COLORSCHEME] = colorscheme)
        cmd = setenv(Cmd(args), env)
        proc = run(pipeline(cmd; stdin=devnull, stdout=devnull, stderr=stderr); wait=false)
        wait(proc)
        success(proc) || error("nvim exited with status $(proc.exitcode); nothing written")
        isfile(outfile) || error("nvim did not produce output; check that your config loads headlessly")
        result = Dict{String,Hl}()
        for line in eachline(outfile)
            isempty(line) && continue
            name, fg, bg, attrs = split(line, '\t')
            result[String(name)] = Hl(fg == "NONE" ? nothing : String(fg),
                bg == "NONE" ? nothing : String(bg),
                attrs == "NONE" ? Set{String}() : Set(String.(split(attrs, ','))))
        end
        return result
    end
end

function nvim_colorscheme_name()
    # Ask nvim for the active colorscheme name, for the header comment
    try
        out = read(`nvim --headless -c 'lua io.stdout:write(vim.g.colors_name or "unknown")' -c 'qall!'`, String)
        return strip(out)
    catch
        return "unknown"
    end
end

# ---------------------------------------------------------------------------
# 3. Build faces
# ---------------------------------------------------------------------------

# A face is an ordered list of TOML key => value pairs.
const Face = Vector{Pair{String,Any}}

function attr_pairs(hl::Hl)
    pairs = Pair{String,Any}[]
    "bold" in hl.attrs && push!(pairs, "weight" => "bold")
    "italic" in hl.attrs && push!(pairs, "slant" => "italic")
    "underline" in hl.attrs && push!(pairs, "underline" => true)
    "strikethrough" in hl.attrs && push!(pairs, "strikethrough" => true)
    "reverse" in hl.attrs && push!(pairs, "inverse" => true)
    return pairs
end

function build_face(spec::FaceSpec, hls::Dict{String,Hl})
    face = Face()
    # Pick the first group that has any foreground or background color, and
    # (if `distinct_from` is set) that actually differs from that reference group
    hl = nothing
    ref = spec.distinct_from === nothing ? nothing : get(hls, spec.distinct_from, nothing)
    for g in spec.groups
        h = get(hls, g, nothing)
        h === nothing && continue
        (h.fg !== nothing || h.bg !== nothing) || continue
        (ref !== nothing && h == ref) && continue
        hl = h
        break
    end
    if hl !== nothing
        hl.fg === nothing || push!(face, "foreground" => hl.fg)
        hl.bg === nothing || push!(face, "background" => hl.bg)
        append!(face, attr_pairs(hl))
    end
    inherit = hl === nothing ? vcat(spec.inherit, spec.fallback_inherit) : spec.inherit
    isempty(inherit) || push!(face, "inherit" => inherit)
    # Add fixed extras, but don't duplicate a key already set from the highlight
    for (k, v) in spec.extra
        any(p -> first(p) == k, face) || push!(face, k => v)
    end
    return face
end

"Pick `n` distinct colors for rainbow faces, preferring plugin-defined groups."
function rainbow_colors(hls::Dict{String,Hl})
    plugin = String[]
    for g in RAINBOW_PLUGIN_GROUPS
        h = get(hls, g, nothing)
        h !== nothing && h.fg !== nothing && push!(plugin, h.fg)
    end
    isempty(plugin) || return plugin
    # Fallback: distinct foregrounds from the theme's own palette
    colors = String[]
    for g in RAINBOW_FALLBACK_GROUPS
        h = get(hls, g, nothing)
        h !== nothing && h.fg !== nothing && !(h.fg in colors) && push!(colors, h.fg)
    end
    return colors
end

# By default the rainbow faces just inherit from julia_parentheses, so every
# bracket matches the theme like it does in nvim. With `rainbow=true`, cycle
# through plugin-defined rainbow colors (or a fallback palette) by depth.
function build_rainbow_faces(hls::Dict{String,Hl}; rainbow::Bool=false)
    colors = rainbow ? rainbow_colors(hls) : String[]
    faces = Pair{String,Face}[]
    # Each kind: (name, number of distinct colors in its cycle, starting offset into palette)
    # Offsets stagger the palettes so parens/brackets/curlies don't all start on the same color.
    for (kind, ncolors, offset) in [("paren", 3, 0), ("bracket", 2, 3), ("curly", 2, 5)]
        for i in 1:6
            name = "julia_rainbow_$(kind)_$i"
            face = Face()
            if i <= ncolors
                if !isempty(colors)
                    push!(face, "foreground" => colors[mod1(offset + i, length(colors))])
                end
                push!(face, "inherit" => ["julia_parentheses"])
            else
                # Levels beyond the cycle inherit from the matching earlier level
                push!(face, "inherit" => ["julia_rainbow_$(kind)_$(mod1(i, ncolors))"])
            end
            push!(faces, name => face)
        end
    end
    return faces
end

# ---------------------------------------------------------------------------
# 4. Write TOML
# ---------------------------------------------------------------------------

toml_value(v::String) = "\"$v\""
toml_value(v::Bool) = string(v)
toml_value(v::Vector{String}) = length(v) == 1 ? toml_value(v[1]) : "[" * join(toml_value.(v), ", ") * "]"

function write_toml(io::IO, faces::Vector{Pair{String,Face}}, colorscheme::AbstractString)
    println(io, "# Generated by nvim2juliarepl from Neovim colorscheme: ", colorscheme)
    for (name, face) in faces
        isempty(face) && continue  # nothing to set
        println(io)
        println(io, "[", name, "]")
        for (k, v) in face
            println(io, k, " = ", toml_value(v))
        end
    end
end

# ---------------------------------------------------------------------------
# 5. CLI
# ---------------------------------------------------------------------------

const DEFAULT_OUTPUT = joinpath(first(DEPOT_PATH), "config", "faces.toml")

const HELP = """
usage: nvim2juliarepl [options]

Convert your Neovim colorscheme into a Julia REPL syntax highlighting theme.

Starts a headless Neovim (which loads your normal config and colorscheme), reads
the colors of highlight groups such as `@keyword` and `@string`, maps them onto
the `julia_*` faces used by the Julia 1.13+ REPL, and writes them to a
StyledStrings `faces.toml` that your REPL will pick up.

Options:
  -o, --output PATH       Where to write the faces file.
                          Default: $DEFAULT_OUTPUT
  -c, --colorscheme NAME  Use this Neovim colorscheme instead of the one your
                          config activates.
  -f, --force             Overwrite the output file if it already exists.
  -r, --rainbow           Color brackets by nesting depth, using the colors from
                          a rainbow-brackets plugin if one is installed, or a
                          palette taken from the colorscheme otherwise. Without
                          this flag all brackets get the same color, as in nvim.
  -h, --help              Show this help and exit.

Requires `nvim` (0.9+) on PATH.
"""

function parse_args(args)
    opts = Dict{String,Any}("output" => DEFAULT_OUTPUT,
        "colorscheme" => nothing, "force" => false, "rainbow" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--output" || a == "-o"
            opts["output"] = args[i+=1]
        elseif a == "--colorscheme" || a == "-c"
            opts["colorscheme"] = args[i+=1]
        elseif a == "--force" || a == "-f"
            opts["force"] = true
        elseif a == "--rainbow" || a == "-r"
            opts["rainbow"] = true
        elseif a == "--help" || a == "-h"
            print(HELP)
            exit(0)
        else
            println(stderr, "error: unknown argument: $a (try --help)")
            exit(1)
        end
        i += 1
    end
    return opts
end

function run_cli(args)
    opts = parse_args(args)
    output = opts["output"]
    if isfile(output) && !opts["force"]
        println(stderr, "error: $output already exists; pass --force to overwrite or --output to choose another path")
        exit(1)
    end

    groups = unique(vcat([g for s in FACE_SPECS for g in s.groups],
        RAINBOW_FALLBACK_GROUPS, RAINBOW_PLUGIN_GROUPS))
    hls = query_nvim(groups; colorscheme=opts["colorscheme"])
    colorscheme = something(opts["colorscheme"], nvim_colorscheme_name())

    faces = Pair{String,Face}[s.name => build_face(s, hls) for s in FACE_SPECS]
    append!(faces, build_rainbow_faces(hls; rainbow=opts["rainbow"]))

    mkpath(dirname(output))
    open(output, "w") do io
        write_toml(io, faces, colorscheme)
    end
    println("Wrote ", output, " (colorscheme: ", colorscheme, ")")
end

# `julia -m NvimToREPLColor [args]`
function (@main)(args)
    try
        run_cli(args)
    catch e
        # Expected failures (nvim errors, bad config) get a one-line message
        # rather than a stacktrace; anything else is a bug, so rethrow.
        e isa ErrorException || rethrow()
        println(stderr, "error: ", e.msg)
        return 1
    end
    return 0
end

end # module NvimToREPLColor
