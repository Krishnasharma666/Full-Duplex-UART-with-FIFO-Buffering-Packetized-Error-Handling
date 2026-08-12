# AXI Slave RAM Controller

A Verilog project that implements an **AXI-style slave interface** connected to a **1024 x 32-bit on-chip RAM**, along with a **self-checking testbench** that exercises it with a variety of read/write burst scenarios.

If you're new to AXI, don't worry — this README explains the protocol basics alongside the code, so you don't need prior AXI experience to follow along.

---

## 1. What's in this project

| File | What it is |
|---|---|
| `RAM.v` | A simple synchronous, byte-write-enabled memory (`module ram`) |
| `SLAVE.v` | The AXI slave interface (`module axi_lite_slave`) that talks to a bus master and drives the RAM |
| `testbench.v` | A testbench (`module tb_axi4_slave`) that acts as a bus master, sends transactions to the slave, and checks the responses |

**Big picture:** an external "master" (e.g. a CPU or DMA engine) wants to read and write memory over the AXI bus. `axi_lite_slave` is the translator that sits between the AXI bus and the physical RAM — it understands AXI handshakes, works out which memory address is being accessed, and forwards the request to the `ram` module.

```
        AXI Bus                     ┌──────────────┐        ┌───────────┐
 Master ───────────────────────────▶│ axi_lite_slave│───────▶│    ram    │
        (address, data, handshakes) │   (SLAVE.v)   │        │  (RAM.v)  │
                                     └──────────────┘        └───────────┘
```

---

## 2. A 60-second primer on AXI

AXI splits a transaction into up to **5 independent channels**, each with its own `VALID`/`READY` handshake:

| Channel | Direction | Purpose |
|---|---|---|
| Write Address (AW) | Master → Slave | "I want to write starting at this address" |
| Write Data (W) | Master → Slave | The actual data being written |
| Write Response (B) | Slave → Master | "Your write finished, here's the status" |
| Read Address (AR) | Master → Slave | "I want to read starting at this address" |
| Read Data (R) | Slave → Master | The actual data being read back |

**The handshake rule:** data only transfers on a clock edge where **both** `VALID` (asserted by the sender) and `READY` (asserted by the receiver) are high at the same time. This lets either side apply backpressure.

This design also supports **bursts** — a single address phase can cover multiple back-to-back data beats (up to 16, since the length field is 4 bits: `AWLEN`/`ARLEN` = beats − 1). Three burst types are used here:

- `FIXED (2'b00)` – every beat writes/reads the *same* address (useful for FIFOs)
- `INCR (2'b01)` – the address increments by one word after every beat
- `WRAP (2'b10)` – the address increments but wraps back around within an aligned address block (useful for cache-line refills)

> **Note:** the module is named `axi_lite_slave`, but it actually implements burst-capable signals (`AWLEN`, `ARLEN`, `AWBURST`, `ARBURST`, `WLAST`, `RLAST`) that real **AXI-Lite** doesn't have (AXI-Lite is always single-beat). Functionally, this is closer to a simplified **AXI4** slave. Just something to be aware of if you're comparing it against the official AXI-Lite spec.

---

## 3. `RAM.v` — The Memory

```verilog
module ram(input clk, input rst_n, input w_en, input r_en,
           input [9:0] w_addr, input [31:0] d_in, input [9:0] r_addr,
           input [3:0] w_strb, output reg [31:0] d_out);
```

- **Size:** `1024 x 32-bit` words (address width = 10 bits → 2^10 = 1024 locations)
- **Writes:** happen every clock edge that `w_en` is high. `w_strb` (write strobe) is a 4-bit mask — each bit enables writing one byte lane of the 32-bit word:
  - `w_strb[3]` → bits `[31:24]`
  - `w_strb[2]` → bits `[23:16]`
  - `w_strb[1]` → bits `[15:8]`
  - `w_strb[0]` → bits `[7:0]`

  This lets a master write just 1, 2, 3, or 4 bytes of a word without disturbing the others.
- **Reads:** are registered (synchronous) — when `r_en` is high, `d_out` is loaded with `memory[r_addr]` on the *next* clock edge, not immediately. This models a typical one-cycle-latency memory.
- **Reset:** only affects `d_out` (clears it to 0). The memory contents themselves are not reset — this is normal for RAM models (real memory doesn't get wiped by a reset signal).

---

## 4. `SLAVE.v` — The AXI Interface

This is the heart of the project. It's built from **two independent finite state machines (FSMs)** — one for writes, one for reads — plus some **address decoding logic** they both share.

### 4.1 Address decoding & burst math

The AXI address (`AWADDR`/`ARADDR`) is a **byte address**, but the RAM is addressed in 32-bit **words**. So the slave first converts:

```verilog
wire [12:0] shift_address_w = S_AXI_AWADDR >> 2;   // byte address → word address
```

(Shifting right by 2 divides by 4, since each word is 4 bytes.)

From there it computes a few things used to keep bursts inside legal bounds:

| Signal | Meaning |
|---|---|
| `lower_wrap_bnd_w/r`, `upper_wrap_bnd_w/r` | The aligned start/end word address of a **WRAP** burst, so wrapping addresses know where to "loop back" to |
| `burst_bytes_w/r` | Total bytes the whole burst will transfer (`(AWLEN+1) << AWSIZE`) |
| `final_addr_w/r` | The last byte address touched by the burst |
| `boundary_err_w/r` | Flags an error if an `INCR` burst would cross a 4KB boundary — a real rule from the AXI spec, since AXI interconnects route transactions in 4KB chunks and a burst is not allowed to cross that line |

### 4.2 Error checking

Two conditions are checked per transaction, and reported back via the response channel:

1. **`AWSIZE`/`ARSIZE` must be `3'b010`** (i.e. 4 bytes per beat = `2^2`). Since the RAM is word-addressed, any other beat size isn't supported — asking for something else raises an error.
2. **4KB boundary crossing** (`boundary_err_w/r`, described above) on `INCR` bursts.

If either condition trips, `error_check_w`/`error_check_r` is set, and the response channel returns:

```verilog
localparam OKAY   = 2'b00;  // success
localparam SLVERR = 2'b10;  // slave error
```

Note that even on an error, the slave still completes the full handshake sequence — it just flags `SLVERR` in the response. It doesn't corrupt or block the bus.

### 4.3 Write FSM

```
 idle_write ─▶ address_fetch_write ─▶ data_transfer_write ─▶ write_response ─▶ buffer_state_write ─▶ (back to idle_write)
```

| State | What happens |
|---|---|
| `idle_write` | Assert `AWREADY` = 1 (slave says "I can accept a write address") |
| `address_fetch_write` | Waits for `AWVALID`. Once seen: latch the starting address, run the size/boundary checks, load `write_counter` with `AWLEN`, and open the data channel (`WREADY` = 1) |
| `data_transfer_write` | For every beat where `WVALID` is high: advance the write address according to the burst type (`FIXED` stays put, `INCR` goes up by 1, `WRAP` goes up and loops at the wrap boundary), and decrement `write_counter`. When the counter hits zero, the burst is done |
| `write_response` | Assert `BVALID` = 1 with `BRESP` set to `OKAY` or `SLVERR` depending on whether an error was flagged earlier |
| `buffer_state_write` | Waits for the master to accept the response (`BREADY`), then returns to `idle_write` for the next transaction |

### 4.4 Read FSM

```
 idle_read ─▶ address_fetch_read ─▶ data_transfer_read ─▶ (back to idle_read)
```

| State | What happens |
|---|---|
| `idle_read` | Assert `ARREADY` = 1, clear `RVALID`/`RLAST` |
| `address_fetch_read` | Waits for `ARVALID`. Once seen: latch the starting address, run the size/boundary checks, load `read_counter` with `ARLEN` |
| `data_transfer_read` | Raises `RVALID` and, for every beat accepted by the master (`RREADY`), advances the read address per burst type and decrements `read_counter`. Sets `RRESP` per beat. When the counter reaches zero, `RLAST` is asserted (marks the final beat of the burst) and the FSM returns to `idle_read` |

### 4.5 Connecting to the RAM

```verilog
wire w_en = S_AXI_WVALID && S_AXI_WREADY;   // a write beat actually happened
wire r_en = S_AXI_RREADY;                   // master is ready to accept read data
```

These, along with the FSM-computed `real_address_w`/`real_address_r`, are wired straight into the `ram` instance (`r1`), so the FSMs are effectively just "AXI-speak to simple memory-speak" translators.

---

## 5. `testbench.v` — Verification

The testbench builds a lightweight **Bus Functional Model (BFM)** — reusable Verilog tasks that behave like a real AXI master — and then runs a series of directed test scenarios against the slave.

### 5.1 BFM tasks

- **`axi_write(addr, len, burst, size)`** — drives the AW channel, then streams `len+1` data beats (auto-generated pattern `0xDEAF_0000 + i`) over the W channel, then waits for and checks the B response.
- **`axi_read(addr, len, burst, size)`** — drives the AR channel, then accepts `len+1` beats on the R channel, checking `RRESP` on every beat.

Both tasks are declared `automatic`, which gives each call its own private set of local variables — this is what allows `fork...join` to run a write and a read **at the same time** without them interfering with each other (see Test 8/9 below).

### 5.2 Test plan

| # | Test | What it checks |
|---|---|---|
| 1 | Single Beat Edge Case | The smallest possible burst (`AWLEN = 0`, i.e. 1 beat) works correctly |
| 2 | Max Length INCR Burst | A full 16-beat incrementing burst (`AWLEN = 15`) |
| 3 | FIXED Burst | Repeated writes/reads to the *same* address (FIFO-style access) |
| 4 | Cache-Line WRAP Burst | Address correctly wraps around within an aligned block |
| 5 | Unaligned Address Handling | An address that isn't word-aligned (`0x401`) gets truncated/shifted to the correct word (`0x400`) |
| 6 | Narrow Burst Size Error | Sending `AWSIZE = 1` (2 bytes) instead of the required `2` (4 bytes) should raise `SLVERR` |
| 7 | 4KB Boundary Crossing | A burst starting near `0xFF8` that would cross into the next 4KB page should raise `SLVERR` |
| 8 | Full-Duplex Parallel Transfer | A read and a write happen simultaneously via `fork...join`, both completing cleanly (`OKAY`) |
| 9 | Parallel Stress + Mixed Errors | A simultaneous read (valid) and write (invalid, crosses 4KB) prove the two FSMs operate independently — one throwing `SLVERR` doesn't block or corrupt the other |

Each test prints a labeled banner via `$display`, and the BFM tasks themselves print a warning if a non-`OKAY` response is unexpected, so you can watch the simulation log to confirm behavior.

---

## 6. How to run the simulation

Any standard Verilog simulator will work. For example, with **Icarus Verilog**:

```bash
iverilog -o sim.out RAM.v SLAVE.v testbench.v
vvp sim.out
```

Or in a tool like **ModelSim/QuestaSim** or **Vivado XSIM**, just add all three files to a project and set `tb_axi4_slave` as the top-level simulation module.

Expected output: a sequence of `[TEST n]` banners, with `[WRITE BFM]`/`[READ BFM]` warnings printed **only** on tests 6, 7, and 9 (where an `SLVERR` is intentionally triggered), followed by:

```
==================================================
 ALL VERIFICATION TESTS COMPLETED SUCCESSFULLY
==================================================
```

---

## 7. Signal glossary (quick reference)

| Signal | Meaning |
|---|---|
| `AWADDR` / `ARADDR` | Write / Read starting byte address |
| `AWLEN` / `ARLEN` | Burst length − 1 (e.g. `4'hF` = 16 beats) |
| `AWSIZE` / `ARSIZE` | Bytes per beat, as a power of 2 (`3'b010` = 4 bytes) |
| `AWBURST` / `ARBURST` | Burst type: `00`=FIXED, `01`=INCR, `10`=WRAP |
| `AWVALID` / `WVALID` / `ARVALID` | Master says "this data/address is valid" |
| `AWREADY` / `WREADY` / `ARREADY` | Slave says "I can accept it" |
| `WSTRB` | Byte-lane write mask for the current data beat |
| `WLAST` / `RLAST` | Marks the final beat of a burst |
| `BRESP` / `RRESP` | Response status: `00`=OKAY, `10`=SLVERR |
| `BVALID` / `RVALID` | Slave says "this response/data is valid" |
| `BREADY` / `RREADY` | Master says "I can accept it" |

---

## 8. Known limitations / things to be aware of

- Only **word-aligned, 4-byte-per-beat** accesses are fully supported; anything else triggers `SLVERR` rather than being handled another way.
- The module name (`axi_lite_slave`) doesn't match its actual feature set (burst support), which may be confusing if you're expecting strict AXI-Lite behavior.
- The RAM's read latency is fixed at one cycle; there's no wait-state/backpressure modeling inside the RAM itself (all backpressure happens at the AXI FSM level).
- `real_address_w` and `real_address_r` are 10 bits, matching the RAM's 1024-word depth — addresses beyond this range will alias (wrap) silently rather than error out.

