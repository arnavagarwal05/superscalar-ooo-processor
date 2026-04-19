library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package pkg is

  --------------------------------------------------------------------------
  -- ISA Constants
  --------------------------------------------------------------------------
  constant DATA_W   : integer := 16;  -- data width
  constant REG_BITS : integer := 3;   -- 8 registers
  constant NUM_REGS : integer := 8;
  constant ROB_BITS : integer := 4;   -- 16 ROB entries
  constant ROB_SIZE : integer := 16;
  constant RS_BITS  : integer := 3;   -- 8 RS entries
  constant RS_SIZE  : integer := 8;
  constant SB_BITS  : integer := 3;   -- 8 store buffer entries
  constant SB_SIZE  : integer := 8;
  constant BHT_BITS : integer := 4;   -- 16 BHT entries
  constant BHT_SIZE : integer := 16; --

  --------------------------------------------------------------------------
  -- Opcode constants (top 4 bits of instruction)
  --------------------------------------------------------------------------
  constant OP_ADI : std_logic_vector(3 downto 0) := "0000";
  constant OP_ADD : std_logic_vector(3 downto 0) := "0001";  -- ADD family
  constant OP_NDU : std_logic_vector(3 downto 0) := "0010";  -- NAND family
  constant OP_LLI : std_logic_vector(3 downto 0) := "0011";
  constant OP_LW  : std_logic_vector(3 downto 0) := "0100";
  constant OP_SW  : std_logic_vector(3 downto 0) := "0101";
  constant OP_LM  : std_logic_vector(3 downto 0) := "0110";
  constant OP_SM  : std_logic_vector(3 downto 0) := "0111";
  constant OP_BEQ : std_logic_vector(3 downto 0) := "1000";
  constant OP_BLT : std_logic_vector(3 downto 0) := "1001";
  constant OP_BLE : std_logic_vector(3 downto 0) := "1010";
  constant OP_JAL : std_logic_vector(3 downto 0) := "1100";
  constant OP_JLR : std_logic_vector(3 downto 0) := "1101";
  constant OP_JRI : std_logic_vector(3 downto 0) := "1111";

  --------------------------------------------------------------------------
  -- Decoded instruction record
  -- Everything the decode stage extracts from a 16-bit instruction
  --------------------------------------------------------------------------
  type decoded_instr_t is record
    valid         : std_logic;
    opcode        : std_logic_vector(3 downto 0);
    ra            : std_logic_vector(2 downto 0);
    rb            : std_logic_vector(2 downto 0);
    rc            : std_logic_vector(2 downto 0);
    imm6          : std_logic_vector(5 downto 0);
    imm9          : std_logic_vector(8 downto 0);
    complement    : std_logic;                      -- bit 3 of instruction
    condition     : std_logic_vector(1 downto 0);   -- bits 1:0
    -- derived control signals
    dest_reg      : std_logic_vector(2 downto 0);
    has_dest      : std_logic;
    src1_reg      : std_logic_vector(2 downto 0);   -- separate since src1_reg is not always ra. It tells that this is the 1st source reg of instr. meaningful if has_src = 1
    has_src1      : std_logic;
    src2_reg      : std_logic_vector(2 downto 0);
    has_src2      : std_logic;
    reads_c       : std_logic;
    reads_z       : std_logic;
    writes_c      : std_logic;
    writes_z      : std_logic;
    is_predicated : std_logic;
    is_branch     : std_logic;
    is_jump       : std_logic;   -- unconditional: JAL, JLR, JRI
    is_store      : std_logic;
    is_load       : std_logic;
    pc            : std_logic_vector(15 downto 0);
  end record;

  -- Default / empty decoded instruction
  constant DECODED_NOP : decoded_instr_t := (
    valid => '0', opcode => "0000",
    ra => "000", rb => "000", rc => "000",
    imm6 => "000000", imm9 => "000000000",
    complement => '0', condition => "00",
    dest_reg => "000", has_dest => '0',
    src1_reg => "000", has_src1 => '0',
    src2_reg => "000", has_src2 => '0',
    reads_c => '0', reads_z => '0',
    writes_c => '0', writes_z => '0',
    is_predicated => '0', is_branch => '0', is_jump => '0',
    is_store => '0', is_load => '0',
    pc => x"0000"
  );

  --------------------------------------------------------------------------
  -- RS entry record
  --------------------------------------------------------------------------
  type rs_entry_t is record
    busy          : std_logic;
    opcode        : std_logic_vector(3 downto 0);
    complement    : std_logic;
    condition     : std_logic_vector(1 downto 0);
    -- operand 1
    opr1          : std_logic_vector(15 downto 0);  -- value if v1=1, tag in lower bits if v1=0
    v1            : std_logic;
    -- operand 2
    opr2          : std_logic_vector(15 downto 0);
    v2            : std_logic;
    -- flag operands
    needs_c       : std_logic;
    c_val         : std_logic;   -- flag value if c_ready=1
    c_tag         : std_logic_vector(3 downto 0);  -- ROB tag if c_ready=0
    c_ready       : std_logic;
    needs_z       : std_logic;
    z_val         : std_logic;
    z_tag         : std_logic_vector(3 downto 0);
    z_ready       : std_logic;
    -- metadata
    rob_tag       : std_logic_vector(3 downto 0);   -- this is how the execute unit knows what to put on the CDB.
    dest_reg      : std_logic_vector(2 downto 0);   -- carried so that ROB/retire know where to write back
    pc            : std_logic_vector(15 downto 0);  -- needed for branch target computation
    imm           : std_logic_vector(15 downto 0);  -- sign-extended immediate
    is_predicated : std_logic;
    is_store      : std_logic;
    is_load       : std_logic;
    is_branch     : std_logic;
    is_jump       : std_logic;
    age           : unsigned(3 downto 0);           -- for oldest-first issue if multiple are ready simultaneously
    -- branch prediction info (carried to execute for misprediction detection)
    predicted_taken  : std_logic;
    predicted_target : std_logic_vector(15 downto 0);
    old_dest_val    : std_logic_vector(15 downto 0);  -- value of dest reg before this instruction (NOP pass-through)
    old_dest_tag    : std_logic_vector(3 downto 0);   -- ROB tag to wait for if old value not yet available
    old_dest_ready  : std_logic;                      -- 1 = old_dest_val is valid, 0 = waiting for old_dest_tag
  end record;

-- RS implements decoupled excution. since instructions wait unknown number of cycles, during this wait, there is no pipeline reg holding their context, so rs entry is their pipeline reg hence so many fields.

  type rs_array_t is array (0 to RS_SIZE-1) of rs_entry_t;

  --------------------------------------------------------------------------
  -- ROB entry record
  --------------------------------------------------------------------------
  type rob_entry_t is record
    valid           : std_logic;
    done            : std_logic;
    pc              : std_logic_vector(15 downto 0);
    dest_reg        : std_logic_vector(2 downto 0);
    has_dest        : std_logic;
    result          : std_logic_vector(15 downto 0);
    writes_c        : std_logic;
    writes_z        : std_logic;
    c_val           : std_logic;
    z_val           : std_logic;
    is_nop          : std_logic;
    is_branch       : std_logic;
    is_jump         : std_logic;
    is_store        : std_logic;
    predicted_taken : std_logic;
    predicted_target: std_logic_vector(15 downto 0);
    branch_taken    : std_logic;
    branch_target   : std_logic_vector(15 downto 0);
    mispredicted    : std_logic;
    old_dest_val    : std_logic_vector(15 downto 0);  -- for NOP pass-through
  end record;

  constant ROB_ENTRY_EMPTY : rob_entry_t := (
    valid => '0', done => '0', pc => x"0000",
    dest_reg => "000", has_dest => '0',
    result => x"0000",
    writes_c => '0', writes_z => '0',
    c_val => '0', z_val => '0',
    is_nop => '0', is_branch => '0', is_jump => '0', is_store => '0',
    predicted_taken => '0', predicted_target => x"0000",
    branch_taken => '0', branch_target => x"0000",
    mispredicted => '0', old_dest_val => x"0000"
  );

  type rob_array_t is array (0 to ROB_SIZE-1) of rob_entry_t;

  --------------------------------------------------------------------------
  -- RAT entry: valid bit + ROB tag
  --------------------------------------------------------------------------
  type rat_entry_t is record
    valid   : std_logic;        -- 1 = value comes from ROB, 0 = read ARF
    rob_tag : std_logic_vector(3 downto 0);
  end record;

  constant RAT_ENTRY_CLEAR : rat_entry_t := (valid => '0', rob_tag => "0000");

  type rat_array_t is array (0 to NUM_REGS-1) of rat_entry_t;

  --------------------------------------------------------------------------
  -- Store buffer entry
  --------------------------------------------------------------------------
  type sb_entry_t is record
    valid     : std_logic;
    addr      : std_logic_vector(15 downto 0);
    data      : std_logic_vector(15 downto 0);
    rob_tag   : std_logic_vector(3 downto 0);
    committed : std_logic;
  end record;

  constant SB_ENTRY_EMPTY : sb_entry_t := (
    valid => '0', addr => x"0000", data => x"0000",
    rob_tag => "0000", committed => '0'
  );

  type sb_array_t is array (0 to SB_SIZE-1) of sb_entry_t;

  --------------------------------------------------------------------------
  -- CDB bus record
  --------------------------------------------------------------------------
  type cdb_t is record
    valid     : std_logic;
    rob_tag   : std_logic_vector(3 downto 0);
    result    : std_logic_vector(15 downto 0);
    c_val     : std_logic;
    z_val     : std_logic;
    writes_c  : std_logic;
    writes_z  : std_logic;
    is_nop    : std_logic;
    -- branch info
    is_branch    : std_logic;
    branch_taken : std_logic;
    branch_target: std_logic_vector(15 downto 0);
    mispredicted : std_logic;
    -- store info
    is_store     : std_logic;
    store_addr   : std_logic_vector(15 downto 0);
    store_data   : std_logic_vector(15 downto 0);
    -- load info
    is_load      : std_logic;
  end record;

  constant CDB_EMPTY : cdb_t := (
    valid => '0', rob_tag => "0000", result => x"0000",
    c_val => '0', z_val => '0', writes_c => '0', writes_z => '0',
    is_nop => '0',
    is_branch => '0', branch_taken => '0', branch_target => x"0000",
    mispredicted => '0',
    is_store => '0', store_addr => x"0000", store_data => x"0000",
    is_load => '0'
  );

  --------------------------------------------------------------------------
  -- Register file type
  --------------------------------------------------------------------------
  type reg_file_t is array (0 to NUM_REGS-1) of std_logic_vector(15 downto 0);

  --------------------------------------------------------------------------
  -- Helper: sign extend 6 bits to 16 bits
  --------------------------------------------------------------------------
  function sign_ext6(x : std_logic_vector(5 downto 0)) return std_logic_vector;

  --------------------------------------------------------------------------
  -- Helper: sign extend 9 bits to 16 bits
  --------------------------------------------------------------------------
  function sign_ext9(x : std_logic_vector(8 downto 0)) return std_logic_vector;

end package;

package body pkg is

  function sign_ext6(x : std_logic_vector(5 downto 0)) return std_logic_vector is
    variable result : std_logic_vector(15 downto 0);
  begin
    result(5 downto 0) := x;
    result(15 downto 6) := (others => x(5));  -- sign bit
    return result;
  end function;

  function sign_ext9(x : std_logic_vector(8 downto 0)) return std_logic_vector is
    variable result : std_logic_vector(15 downto 0);
  begin
    result(8 downto 0) := x;
    result(15 downto 9) := (others => x(8));
    return result;
  end function;

end package body;
