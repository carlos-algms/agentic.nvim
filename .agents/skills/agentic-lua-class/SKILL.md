---
name: agentic-lua-class
description: >
  MANDATORY before writing or editing ANY .lua file in this repo - classes,
  methods, fields, functions, or LuaCATS annotations. Holds the project's
  enforced Lua style: class pattern, visibility prefixes (_private,
  __protected), and optional-type syntax. Skipping it produces luals/selene
  failures at make validate. Load it before the first edit, not after.
---

# Lua Class Pattern

**Basic class structure:**

```lua
--- @class Animal
local Animal = {}
Animal.__index = Animal

function Animal:new()
    self = setmetatable({}, self)
    return self
end

function Animal:move()
    print("Animal moves")
end
```

**Key points:**

- Set `__index` to `self` for inheritance
- Use `setmetatable` to create instances
- Return the instance from constructor

**Method definition syntax:**

- `function Class:method()` - Instance method, receives `self` implicitly
  - Called as: `instance:method()` or `instance.method(instance)`
  - Use for methods that need access to instance state

- `function Class.method()` - Module function, static, does NOT receive `self`
  - Called as: `Class.method()` or `instance.method()` (both work, but no
    `self`)
  - Use for utility functions, constructors, or static helpers

## Inheritance Pattern

**Class setup (module-level):**

```lua
local Parent = {}
Parent.__index = Parent

--- @class Child : Parent
local Child = setmetatable({}, { __index = Parent })
Child.__index = Child
```

**Constructor with parent initialization:**

```lua
function Parent:new(name)
    local instance = {
        name = name,
        parent_state = {}
    }
    return setmetatable(instance, self)
end

function Child:new(name, extra)
    -- Call parent constructor with Parent class
    local instance = Parent.new(Parent, name)

    -- Add child-specific state
    instance.child_state = extra

    -- Re-metatable to child class for proper inheritance chain
    return setmetatable(instance, Child)
end
```

**Critical rules:**

- **Always pass parent class explicitly:** `Parent.new(Parent, ...)` not
  `Parent.new(self, ...)`
- **Re-assign metatable to child class** after parent initialization
- **Inheritance chain:** `instance → Child → Parent`

**Calling parent methods:**

```lua
function Child:move()
    Parent.move(self)  -- Explicit parent method call
    print("Child-specific movement")
end
```

## Class Design Guidelines: creating and modifying

- **Minimize class properties** - Only include properties that:
  - Are accessed by external code (other modules/classes)
  - Are part of the public API
  - Need to be accessed by subclasses

- **Use visibility prefixes for encapsulation** - Control what external code can
  access:

  **Visibility levels (configured in `.luarc.json`):**
  - `_*`: **Private** - Hidden from external consumers (applies to class
    methods/fields ONLY)
  - `__*`: **Protected** - Visible to subclasses
  - No prefix: **Public** - Visible everywhere

  **IMPORTANT:** Module-level local functions and variables do NOT need `_`
  prefix:
  - ✅ `local function helper()` - correct (already private by `local` scope)
  - ❌ `local function _helper()` - incorrect (redundant `_` prefix)
  - ✅ `local config = {}` - correct
  - ❌ `local _config = {}` - incorrect (redundant `_` prefix)
  - ✅ `function MyClass:_private_method()` - correct (class method needs `_`)
  - ✅ `@field _private_field` - correct (class field needs `_`)

  ```lua
  -- ❌ Bad: Unnecessary public exposure of `counter` property, not used externally
  --- @class MyClass
  --- @field counter number
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({ counter = 0 }, self)
  end

  -- ✅ Good: Proper visibility control
  --- @class MyClass
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({
        -- Counter is internal state, not exposed publicly
        _counter = 0
      }, self)
  end

  --- @protected
  function MyClass:__protected_method()
      self._counter = self._counter + 1
  end

  --- Module-level helper functions (no underscore prefix needed)
  local function format_value(val)
      return tostring(val)
  end

  --- @class Child : MyClass
  function Child:use_parent_state()
      self:__protected_method()
  end
  ```

  **Note:** The `@private` annotation is NOT necessary for private class methods
  - LuaLS infers privacy from the `_` prefix automatically
  - Only use `@protected` for protected methods (`__*`, luals limitation)

- **Document intent with LuaCATS** - Use visibility annotations:

  ```lua
  --- @class MyClass
  --- @field public_field string Public API
  --- @field __protected_field table For subclasses
  --- @field _private_field number Internal only
  ```

- **Regular cleanup** - When adding new code, review class definitions and
  remove:
  - Unused properties
  - Properties that were needed during development but are no longer used
  - Properties that could be local variables instead

## LuaCATS annotation syntax

Space after `---` for descriptions and annotations. Do NOT write param/return
descriptions unless requested. Group related annotations together.

### Return format

`@return {type} return_name description` (type first, then name).

- RIGHT: `@return boolean success Whether the operation succeeded`
- WRONG: `@return boolean Whether the operation succeeded` (missing name)
- WRONG: `@return success boolean` (wrong order)

### Optional types

Format depends on annotation type. See
[LuaLS issue #2385](https://github.com/LuaLS/lua-language-server/issues/2385)
for the underlying validator limitation.

**`@param` and `fun()` - MUST use `type|nil`:**

- RIGHT: `@param winid number|nil`
- RIGHT: `@param callback fun(result: table|nil)`
- WRONG: `@param winid? number` (LuaLS does not validate optional syntax)
- WRONG: `fun(result?: table)` (optional syntax ignored)

**`@field` - Use `variable? type`:**

- RIGHT: `@field _state? string`
- RIGHT: `@field diff? { all?: boolean }` (inline tables also use `?`)
- WRONG: `@field _state string|nil` (use `?` here instead)
- WRONG: `@field _state string?` (`?` goes after variable name, not type)

For a partial variant of an existing class, use `@class (partial)` extending the
source type instead of re-declaring every field as optional.

- RIGHT: `@class (partial) MyOptsOverride: MyOpts`
- WRONG: re-listing `@field field? type` for every field from `MyOpts`

**`@return`, `@type`, `@alias` - Use explicit `type|nil`:**

- RIGHT: `@return string|nil result`, `@type table<string, number|nil>`,
  `@alias MyType string|nil`
- WRONG: trailing `?` on the type (e.g. `string?`, `number?`)

### Typed variables before return

LuaLS cannot infer types from inline returns of complex types. Use a typed
intermediate variable:

```lua
-- Bad: LuaLS cannot infer the return type
function M.create_block(lines)
    return {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
end

-- Good: Type annotation enables proper type checking
--- @return MyModule.Block block
function M.create_block(lines)
    --- @type MyModule.Block
    local block = {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
    return block
end
```

## Appending to typed arrays

Use `arr[#arr + 1] = value`, not `table.insert(arr, value)`, when `arr` has a
LuaCATS element type (`string[]`, `agentic.acp.Content[]`, a typed field, etc.).

`table.insert`'s second arg is variadic `any`, so LuaLS skips
`assign-type-mismatch` (an Error in `.luarc.json`). The indexed-assignment form
is type-checked against the element type and catches wrong-type appends and
stale `@return` / `@type` annotations.

- RIGHT: `lines[#lines + 1] = value` (flags a non-string pushed to `string[]`)
- WRONG: `table.insert(lines, value)` (push silently accepted)

`table.insert` stays fine for positional inserts (`table.insert(t, i, v)`) and
untyped scratch tables where no element type is declared.
