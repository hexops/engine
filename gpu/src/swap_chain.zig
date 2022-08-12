const ChainedStruct = @import("types.zig").ChainedStruct;
const PresentMode = @import("types.zig").PresentMode;
const Texture = @import("texture.zig").Texture;

pub const SwapChain = enum(usize) {
    _,

    // TODO: verify there is a use case for nullable value of this type.
    pub const none: SwapChain = @intToEnum(SwapChain, 0);

    pub const Descriptor = extern struct {
        next_in_chain: *const ChainedStruct,
        label: ?[*:0]const u8 = null,
        usage: Texture.UsageFlags,
        format: Texture.Format,
        width: u32,
        height: u32,
        present_mode: PresentMode,
        implementation: u64,
    };
};
