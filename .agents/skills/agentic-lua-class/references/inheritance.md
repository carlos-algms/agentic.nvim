# Inheritance pattern

ADR 0005 rejects per-provider
subclasses of `ACPClient`. Load this file only when you add a subclass.

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
