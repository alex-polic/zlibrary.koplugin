-- A tab with `rows` (My Books' Booklists) shares one Menu with book tabs. Drives the real module,
-- widgets stubbed, through switches between the two kinds of row.

local PLUGIN = assert(arg[1], "usage: luajit booklist_rows_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

local noop = function() end
local function passthrough(module)
    package.preload[module] = function()
        return { new = function(_, spec) return spec end }
    end
end

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
            scaleBySize = function(_, n) return n end,
        },
        isTouchDevice = function() return true end,
        hasDPad = function() return false end,
        useDPadAsActionKeys = function() return false end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1, COLOR_BLACK = 0 } end
package.preload["ui/size"] = function()
    return { padding = { default = 3, button = 1 }, border = { thin = 1 },
             item = { height_default = 10 } }
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
local shown = {}
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, f) f() end, close = noop, setDirty = noop,
             show = function(_, widget) table.insert(shown, widget) end }
end
passthrough("ui/widget/iconbutton")
passthrough("ui/widget/buttondialog")
passthrough("ui/widget/titlebar")
passthrough("ui/widget/horizontalgroup")
passthrough("ui/widget/verticalgroup")
passthrough("ui/widget/container/framecontainer")
package.preload["ui/widget/toggleswitch"] = function()
    return { new = function(_, spec)
        spec.setPosition = function(self, position) self.position = position end
        spec.disableFocusManagement = noop
        return spec
    end }
end
package.preload["ui/widget/container/inputcontainer"] = function()
    local InputContainer = { onKeyPress = function() return false end, free = noop }
    function InputContainer:extend(fields)
        local cls = fields or {}
        setmetatable(cls, { __index = self })
        function cls:new(o)
            local instance = o or {}
            setmetatable(instance, { __index = cls })
            instance:init()
            return instance
        end
        return cls
    end
    return InputContainer
end

local MenuStub = {}
function MenuStub.new(_, spec)
    spec.updateItems = function(self) self.updates = (self.updates or 0) + 1 end
    return spec
end
function MenuStub.updateItems(menu) if menu then menu.updates = (menu.updates or 0) + 1 end end
package.preload["zlibrary.menu"] = function() return MenuStub end

local cache_store = {}
package.preload["zlibrary.config"] = function()
    return { getMultiSearchCache = function()
        return {
            get = function(_, key) return cache_store[key] end,
            insert = function(_, key, value) cache_store[key] = value end,
            remove = function(_, key) cache_store[key] = nil end,
        }
    end }
end
package.preload["zlibrary.preloader"] = function() return { Preloader = { channel = nil } } end

local SearchDialog = dofile(PLUGIN .. "/zlibrary/multisearch_dialog.lua")

-- ---------------------------------------------------------------- a book tab and a booklist tab
local fetches, opened, selected_books
local function new_dialog(def_position)
    fetches, opened, selected_books = {}, {}, {}
    for key in pairs(cache_store) do cache_store[key] = nil end
    local callback = function(widget, page, is_refresh, fetch_generation)
        table.insert(fetches, { widget = widget, generation = fetch_generation })
    end
    return SearchDialog:new{
        def_position = def_position,
        show_cover = true,
        on_select_book_callback = function(book) table.insert(selected_books, book) end,
        on_download_book_callback = noop,
        toggle_items = {
            { text = "Favorites", cache_key = "favorites", cache_expiry = 60, callback = callback },
            { text = "Booklists", cache_key = "booklists", cache_expiry = 60, callback = callback,
              rows = {
                  show_cover = false,
                  to_menu_item = function(list)
                      return { text = list.name, mandatory = tostring(list.count),
                               callback = function() table.insert(opened, list) end }
                  end,
              } },
        },
    }
end

local function respond(dialog, entries)
    local fetch = fetches[#fetches]
    dialog:setPaginationState(false, 1, fetch.generation)
    dialog:reloadFromBookData(entries, nil, nil, nil, fetch.generation)
end

local BOOK = { id = "1", hash = "h1", title = "Amerika", author = "Kafka", cover = "https://c/1.jpg" }
local LIST = { id = 4066232, name = "Test", count = 22 }

local dialog = new_dialog(1)
local menu = dialog.menu_container
r.check("a book tab opens with covers on", menu.show_cover == true)

dialog:ToggleSwitchCallBack(1)
respond(dialog, { BOOK })
local row = menu.item_table[1]
r.check("a book tab's rows are unchanged",
        row and row.book_index == 1 and row.hash == "h1" and row.cover == "https://c/1.jpg"
            and row.text:find("Amerika", 1, true) and row.text:find("Kafka", 1, true) and not row.callback,
        row and tostring(row.text) or "no row")

-- What the cover layout leaves behind on the shared Menu.
menu.state_w, menu.list_per_page = 50, 4

dialog:ToggleSwitchCallBack(2)
respond(dialog, { LIST })
row = menu.item_table[1]
r.check("a rows tab builds its rows through to_menu_item",
        row and row.text == "Test" and row.mandatory == "22" and row.book_index == nil,
        row and tostring(row.text) or "no row")
r.check("a rows tab with show_cover = false turns covers off", menu.show_cover == false)
r.check("and clears the cover strip", menu.state_w == nil, "state_w=" .. tostring(menu.state_w))
r.check("and restores the user's rows per page", menu.list_per_page == nil,
        "list_per_page=" .. tostring(menu.list_per_page))

menu.onMenuSelect(menu, row)
r.check("a tap on a rows-tab row runs its callback", #opened == 1 and opened[1] == LIST,
        #opened .. " opened")
r.check("and does not treat it as a book", #selected_books == 0, #selected_books .. " books selected")

local shown_before = #shown
menu.onMenuHold(menu, row)
r.check("a hold on a rows-tab row opens nothing", #shown == shown_before)

menu.list_per_page = 10
dialog:ToggleSwitchCallBack(1)
r.check("switching back to a book tab turns covers on again", menu.show_cover == true)
r.check("and lets the menu recompute rows per page", menu.list_per_page == nil,
        "list_per_page=" .. tostring(menu.list_per_page))
row = menu.item_table[1]
r.check("the book tab comes back from cache with book rows", row and row.book_index == 1)
menu.onMenuSelect(menu, row)
r.check("a tap on a book row still selects the book", selected_books[1] == BOOK)

dialog = new_dialog(2)
r.check("a dialog that opens on a rows tab builds its Menu without covers",
        dialog.menu_container.show_cover == false)

-- ---------------------------------------------------------------- a slow booklists response
-- Both tabs fetch page 1, so without its generation the booklists response would pass the page
-- check, land in Favorites, and be cached under its key.
dialog = new_dialog(1)
dialog:ToggleSwitchCallBack(2)
local booklists_fetch = fetches[#fetches]
dialog:ToggleSwitchCallBack(1)
dialog:setPaginationState(false, 1, booklists_fetch.generation)
dialog:reloadFromBookData({ LIST }, nil, nil, nil, booklists_fetch.generation)
r.check("a booklists response that lands after a switch to Favorites is not shown", #dialog.books == 0,
        #dialog.books .. " rows")
r.check("nor cached under favorites", cache_store["favorites"] == nil)

r.finish()
