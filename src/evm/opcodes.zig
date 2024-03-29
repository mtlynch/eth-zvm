const evmc = @cImport({
    @cInclude("evmc/instructions.h");
});

pub const OpCode = enum(u8) {
    ADD = evmc.OP_ADD,
    MOD = evmc.OP_MOD,
    PUSH1 = evmc.OP_PUSH1,
    PUSH32 = evmc.OP_PUSH32,
    MSTORE = evmc.OP_MSTORE,
    PC = evmc.OP_PC,
    RETURN = evmc.OP_RETURN,
    _,
};
