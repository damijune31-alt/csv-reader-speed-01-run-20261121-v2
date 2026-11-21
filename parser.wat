;; csv-reader-speed, WASM SIMD streaming reader (redesign).
;; Byte-through: raw cases.json bytes in, answers.json bytes out.
;; Two passes: (1) JSON unescape of each case's "text" into TEXT with
;; 64-byte SIMD scans; (2) CSV parse into a small span table, then emit
;; answers straight from the spans (no row storage, errors buffered).
;; Semantics replicate csv-reader 1.0.0 exactly.
(module
  (memory (export "memory") 2048 2048)

  ;; Layout: INPUT 0..0x02000000, TEXT 0x02000000 (12 MiB),
  ;; OUT 0x04000000 (48 MiB, build.mjs expects this base),
  ;; ERRBUF 0x07000000 (4 MiB), SPANS 0x07400000 (8192 x 16 B),
  ;; KEYBUF 0x07420000, literals 0x07F00000.
  (global $TEXT_BASE i32 (i32.const 33554432))
  (global $OUT_BASE i32 (i32.const 67108864))
  (global $ERR_BASE i32 (i32.const 117440512))
  (global $SPAN_BASE i32 (i32.const 121634816))
  (global $SPAN_CAP i32 (i32.const 8192))
  (global $KEY_BASE i32 (i32.const 121765888))
  (global $LIT_BASE i32 (i32.const 133169152))

  (global $wp (mut i32) (i32.const 0))
  (global $op (mut i32) (i32.const 0))
  (global $ep (mut i32) (i32.const 0))
  (global $jp (mut i32) (i32.const 0))
  (global $je (mut i32) (i32.const 0))
  (global $tp (mut i32) (i32.const 0))
  (global $te (mut i32) (i32.const 0))
  (global $line (mut i32) (i32.const 1))
  (global $rows_len (mut i32) (i32.const 0))
  (global $width (mut i32) (i32.const -1))
  (global $seen_first (mut i32) (i32.const 0))
  (global $header (mut i32) (i32.const 0))
  (global $spans_n (mut i32) (i32.const 0))
  (global $err_n (mut i32) (i32.const 0))
  (global $first_row (mut i32) (i32.const 1))
  (global $rec_line (mut i32) (i32.const 1))
  (global $rec_row (mut i32) (i32.const 0))
  (global $klen (mut i32) (i32.const 0))
  (global $text_len (mut i32) (i32.const 0))
  (global $uf_end (mut i32) (i32.const 0))
  (global $uf_ended (mut i32) (i32.const 0))
  (global $uf_added (mut i32) (i32.const 0))

  (data (i32.const 0x07F00000) "{\"columns\":")
  (data (i32.const 0x07F0000B) ",\"rows\":[")
  (data (i32.const 0x07F00014) "],\"errors\":[")
  (data (i32.const 0x07F00020) "]}")
  (data (i32.const 0x07F00022) "{\"code\":\"")
  (data (i32.const 0x07F0002B) "\",\"line\":")
  (data (i32.const 0x07F00034) ",\"row\":")
  (data (i32.const 0x07F0003B) ",\"fields\":")
  (data (i32.const 0x07F00045) ",\"extra\":[")
  (data (i32.const 0x07F0004F) "null")
  (data (i32.const 0x07F00053) "stray_cr")
  (data (i32.const 0x07F0005B) "quote_junk")
  (data (i32.const 0x07F00065) "unterminated_quote")
  (data (i32.const 0x07F00077) "short_row")
  (data (i32.const 0x07F00080) "long_row")
  (data (i32.const 0x07F00088) "text")
  (data (i32.const 0x07F0008C) "header")
  (data (i32.const 0x07F00092) "input")
  (data (i32.const 0x07F00097) "id")

  ;; ---- output helpers (all write to $wp) ----
  (func $w8 (param $b i32)
    (i32.store8 (global.get $wp) (local.get $b))
    (global.set $wp (i32.add (global.get $wp) (i32.const 1))))
  (func $wbytes (param $ptr i32) (param $len i32)
    (memory.copy (global.get $wp) (local.get $ptr) (local.get $len))
    (global.set $wp (i32.add (global.get $wp) (local.get $len))))
  (func $wlit (param $off i32) (param $len i32)
    (call $wbytes (i32.add (global.get $LIT_BASE) (local.get $off)) (local.get $len)))
  (func $whex (param $d i32)
    (call $w8 (select (i32.add (local.get $d) (i32.const 48)) (i32.add (local.get $d) (i32.const 87)) (i32.lt_u (local.get $d) (i32.const 10)))))
  (func $wuint (param $n i32)
    (local $p i32) (local $e i32)
    (if (i32.eqz (local.get $n)) (then (call $w8 (i32.const 48)) (return)))
    (local.set $e (i32.const 121766144))
    (local.set $p (local.get $e))
    (loop $d
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p) (i32.add (i32.rem_u (local.get $n) (i32.const 10)) (i32.const 48)))
      (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
      (br_if $d (local.get $n)))
    (call $wbytes (local.get $p) (i32.sub (local.get $e) (local.get $p))))
  (func $wrow
    (if (i32.lt_s (global.get $rec_row) (i32.const 0))
      (then (call $wlit (i32.const 0x4F) (i32.const 4)))
      (else (call $wuint (global.get $rec_row)))))
  (func $use_out (global.set $wp (global.get $op)))
  (func $sync_out (global.set $op (global.get $wp)))
  (func $use_err (global.set $wp (global.get $ep)))
  (func $sync_err (global.set $ep (global.get $wp)))

  ;; ---- 16-byte lane masks ----
  (func $m1 (param $v v128) (param $b i32) (result i32)
    (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (local.get $b)))))
  (func $m3 (param $v v128) (param $b1 i32) (param $b2 i32) (param $b3 i32) (result i32)
    (i32.or (i32.or
      (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (local.get $b1))))
      (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (local.get $b2)))))
      (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (local.get $b3))))))
  ;; escape mask: '"' | '\' | byte<0x20 | 0xED (possible CESU-8 surrogate lead)
  (func $mesc16 (param $v v128) (result i32)
    (i32.or (i32.or
      (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (i32.const 34))))
      (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (i32.const 92)))))
      (i32.or
        (i8x16.bitmask (i8x16.lt_s (v128.xor (local.get $v) (i8x16.splat (i32.const 128))) (i8x16.splat (i32.const 160))))
        (i8x16.bitmask (i8x16.eq (local.get $v) (i8x16.splat (i32.const 237)))))))
  (func $comb4 (param $a i32) (param $b i32) (param $c i32) (param $d i32) (result i64)
    (i64.or (i64.or
      (i64.extend_i32_u (local.get $a))
      (i64.shl (i64.extend_i32_u (local.get $b)) (i64.const 16)))
      (i64.or
        (i64.shl (i64.extend_i32_u (local.get $c)) (i64.const 32))
        (i64.shl (i64.extend_i32_u (local.get $d)) (i64.const 48)))))
  (func $maskoff (param $m i64) (param $rem i32) (result i64)
    (if (result i64) (i32.lt_u (local.get $rem) (i32.const 64))
      (then (i64.and (local.get $m) (i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $rem))) (i64.const 1))))
      (else (local.get $m))))

  ;; ---- 64-byte window scans (result bit i = byte i of the window matches) ----
  ;; unquoted-field delimiters: ',' | LF | CR
  (func $scanU (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (call $m3 (v128.load (local.get $p)) (i32.const 44) (i32.const 10) (i32.const 13))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 16))) (i32.const 44) (i32.const 10) (i32.const 13))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 32))) (i32.const 44) (i32.const 10) (i32.const 13))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 48))) (i32.const 44) (i32.const 10) (i32.const 13)))
      (local.get $rem)))
  ;; quote only
  (func $scanQ (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (call $m1 (v128.load (local.get $p)) (i32.const 34))
        (call $m1 (v128.load (i32.add (local.get $p) (i32.const 16))) (i32.const 34))
        (call $m1 (v128.load (i32.add (local.get $p) (i32.const 32))) (i32.const 34))
        (call $m1 (v128.load (i32.add (local.get $p) (i32.const 48))) (i32.const 34)))
      (local.get $rem)))
  ;; JSON escapes in a string: '"' | '\'
  (func $scanJ (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (call $m3 (v128.load (local.get $p)) (i32.const 34) (i32.const 92) (i32.const 92))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 16))) (i32.const 34) (i32.const 92) (i32.const 92))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 32))) (i32.const 34) (i32.const 92) (i32.const 92))
        (call $m3 (v128.load (i32.add (local.get $p) (i32.const 48))) (i32.const 34) (i32.const 92) (i32.const 92)))
      (local.get $rem)))
  ;; JSON-escape mask only
  (func $scanE (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (call $mesc16 (v128.load (local.get $p)))
        (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 48)))))
      (local.get $rem)))
  ;; escape | CR (unquoted span emit: CR is dropped)
  (func $scanEC (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (i32.or (call $mesc16 (v128.load (local.get $p))) (call $m1 (v128.load (local.get $p)) (i32.const 13)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 16)))) (call $m1 (v128.load (i32.add (local.get $p) (i32.const 16))) (i32.const 13)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 32)))) (call $m1 (v128.load (i32.add (local.get $p) (i32.const 32))) (i32.const 13)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 48)))) (call $m1 (v128.load (i32.add (local.get $p) (i32.const 48))) (i32.const 13))))
      (local.get $rem)))
  ;; escape | '"' | CR | LF (quoted span emit)
  (func $scanQE (param $p i32) (param $rem i32) (result i64)
    (call $maskoff
      (call $comb4
        (i32.or (call $mesc16 (v128.load (local.get $p))) (call $m3 (v128.load (local.get $p)) (i32.const 34) (i32.const 13) (i32.const 10)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 16)))) (call $m3 (v128.load (i32.add (local.get $p) (i32.const 16))) (i32.const 34) (i32.const 13) (i32.const 10)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 32)))) (call $m3 (v128.load (i32.add (local.get $p) (i32.const 32))) (i32.const 34) (i32.const 13) (i32.const 10)))
        (i32.or (call $mesc16 (v128.load (i32.add (local.get $p) (i32.const 48)))) (call $m3 (v128.load (i32.add (local.get $p) (i32.const 48))) (i32.const 34) (i32.const 13) (i32.const 10))))
      (local.get $rem)))

  ;; ---- JSON string escaping of one byte at $p; returns the next position ----
  (func $emit_escape (param $p i32) (result i32)
    (local $b i32) (local $b1 i32) (local $b2 i32) (local $cp i32)
    (local.set $b (i32.load8_u (local.get $p)))
    (if (i32.eq (local.get $b) (i32.const 34))
      (then (call $w8 (i32.const 92)) (call $w8 (i32.const 34)) (return (i32.add (local.get $p) (i32.const 1)))))
    (if (i32.eq (local.get $b) (i32.const 92))
      (then (call $w8 (i32.const 92)) (call $w8 (i32.const 92)) (return (i32.add (local.get $p) (i32.const 1)))))
    (if (i32.eq (local.get $b) (i32.const 237))
      (then
        (local.set $b1 (i32.load8_u (i32.add (local.get $p) (i32.const 1))))
        (if (i32.and (i32.ge_u (local.get $b1) (i32.const 160)) (i32.le_u (local.get $b1) (i32.const 191)))
          (then
            (local.set $b2 (i32.load8_u (i32.add (local.get $p) (i32.const 2))))
            (if (i32.and (i32.ge_u (local.get $b2) (i32.const 128)) (i32.le_u (local.get $b2) (i32.const 191)))
              (then
                ;; CESU-8 lone surrogate -> \uXXXX
                (local.set $cp (i32.add (i32.const 55296)
                  (i32.add (i32.shl (i32.and (local.get $b1) (i32.const 15)) (i32.const 6))
                    (i32.and (local.get $b2) (i32.const 63)))))
                (call $w8 (i32.const 92)) (call $w8 (i32.const 117))
                (call $whex (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 15)))
                (call $whex (i32.and (i32.shr_u (local.get $cp) (i32.const 8)) (i32.const 15)))
                (call $whex (i32.and (i32.shr_u (local.get $cp) (i32.const 4)) (i32.const 15)))
                (call $whex (i32.and (local.get $cp) (i32.const 15)))
                (return (i32.add (local.get $p) (i32.const 3)))))))
        ;; a real U+D000..D7FF char: copy the lead byte raw, the rest follows as clean bytes
        (call $w8 (local.get $b))
        (return (i32.add (local.get $p) (i32.const 1)))))
    (if (i32.ge_u (local.get $b) (i32.const 32))
      (then (call $w8 (local.get $b)) (return (i32.add (local.get $p) (i32.const 1)))))
    ;; control byte -> \u00XX
    (call $w8 (i32.const 92)) (call $w8 (i32.const 117)) (call $w8 (i32.const 48)) (call $w8 (i32.const 48))
    (call $whex (i32.shr_u (local.get $b) (i32.const 4)))
    (call $whex (i32.and (local.get $b) (i32.const 15)))
    (i32.add (local.get $p) (i32.const 1)))

  ;; ---- emit an unquoted span: stray CRs dropped, the rest JSON-escaped ----
  (func $emit_span_unquoted (param $s i32) (param $len i32)
    (local $pos i32) (local $end i32) (local $rem i32) (local $m i64) (local $n i32)
    (local.set $pos (local.get $s))
    (local.set $end (i32.add (local.get $s) (local.get $len)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $rem (i32.sub (local.get $end) (local.get $pos)))
        (local.set $m (call $scanEC (local.get $pos) (local.get $rem)))
        (if (i64.eqz (local.get $m))
          (then
            (local.set $n (select (i32.const 64) (local.get $rem) (i32.gt_u (local.get $rem) (i32.const 64))))
            (memory.copy (global.get $wp) (local.get $pos) (local.get $n))
            (global.set $wp (i32.add (global.get $wp) (local.get $n)))
            (local.set $pos (i32.add (local.get $pos) (local.get $n)))
            (br $l)))
        (local.set $n (i32.wrap_i64 (i64.ctz (local.get $m))))
        (if (i32.gt_u (local.get $n) (i32.const 0))
          (then
            (memory.copy (global.get $wp) (local.get $pos) (local.get $n))
            (global.set $wp (i32.add (global.get $wp) (local.get $n)))))
        (local.set $pos (i32.add (local.get $pos) (local.get $n)))
        (if (i32.eq (i32.load8_u (local.get $pos)) (i32.const 13))
          (then (local.set $pos (i32.add (local.get $pos) (i32.const 1))))
          (else (local.set $pos (call $emit_escape (local.get $pos)))))
        (br $l))))

  ;; ---- emit a quoted span: "" -> ", CR/CRLF/LF -> \n, the rest escaped ----
  (func $emit_span_quoted (param $s i32) (param $len i32)
    (local $pos i32) (local $end i32) (local $rem i32) (local $m i64) (local $n i32) (local $b i32)
    (local.set $pos (local.get $s))
    (local.set $end (i32.add (local.get $s) (local.get $len)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $rem (i32.sub (local.get $end) (local.get $pos)))
        (local.set $m (call $scanQE (local.get $pos) (local.get $rem)))
        (if (i64.eqz (local.get $m))
          (then
            (local.set $n (select (i32.const 64) (local.get $rem) (i32.gt_u (local.get $rem) (i32.const 64))))
            (memory.copy (global.get $wp) (local.get $pos) (local.get $n))
            (global.set $wp (i32.add (global.get $wp) (local.get $n)))
            (local.set $pos (i32.add (local.get $pos) (local.get $n)))
            (br $l)))
        (local.set $n (i32.wrap_i64 (i64.ctz (local.get $m))))
        (if (i32.gt_u (local.get $n) (i32.const 0))
          (then
            (memory.copy (global.get $wp) (local.get $pos) (local.get $n))
            (global.set $wp (i32.add (global.get $wp) (local.get $n)))))
        (local.set $pos (i32.add (local.get $pos) (local.get $n)))
        (local.set $b (i32.load8_u (local.get $pos)))
        (if (i32.eq (local.get $b) (i32.const 34))
          (then
            ;; doubled quote: one " out
            (call $w8 (i32.const 92)) (call $w8 (i32.const 34))
            (local.set $pos (i32.add (local.get $pos) (i32.const 2))))
          (else
            (if (i32.eq (local.get $b) (i32.const 13))
              (then
                (call $w8 (i32.const 92)) (call $w8 (i32.const 110))
                (global.set $line (i32.add (global.get $line) (i32.const 1)))
                (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
                (if (i32.and (i32.lt_u (local.get $pos) (local.get $end))
                      (i32.eq (i32.load8_u (local.get $pos)) (i32.const 10)))
                  (then (local.set $pos (i32.add (local.get $pos) (i32.const 1))))))
              (else
                (if (i32.eq (local.get $b) (i32.const 10))
                  (then
                    (call $w8 (i32.const 92)) (call $w8 (i32.const 110))
                    (global.set $line (i32.add (global.get $line) (i32.const 1)))
                    (local.set $pos (i32.add (local.get $pos) (i32.const 1))))
                  (else (local.set $pos (call $emit_escape (local.get $pos)))))))))
        (br $l))))

  ;; span entry: [start, len, kind, close_off]; kind 0 unquoted, 1 quoted, 2 quoted+junk
  (func $emit_field (param $i i32)
    (local $base i32) (local $s i32) (local $l i32) (local $k i32) (local $c i32)
    (local.set $base (i32.add (global.get $SPAN_BASE) (i32.mul (local.get $i) (i32.const 16))))
    (local.set $s (i32.load (local.get $base)))
    (local.set $l (i32.load (i32.add (local.get $base) (i32.const 4))))
    (local.set $k (i32.load (i32.add (local.get $base) (i32.const 8))))
    (local.set $c (i32.load (i32.add (local.get $base) (i32.const 12))))
    (call $w8 (i32.const 34))
    (if (i32.eq (local.get $k) (i32.const 0))
      (then (call $emit_span_unquoted (local.get $s) (local.get $l)))
      (else
        (call $emit_span_quoted (local.get $s) (local.get $c))
        (if (i32.eq (local.get $k) (i32.const 2))
          (then (call $emit_span_unquoted
            (i32.add (i32.add (local.get $s) (local.get $c)) (i32.const 1))
            (i32.sub (i32.sub (local.get $l) (local.get $c)) (i32.const 1)))))))
    (call $w8 (i32.const 34)))

  ;; emit the current spans as one row (cut to width, padded with "")
  (func $emit_row
    (local $i i32) (local $n i32)
    (if (global.get $first_row)
      (then (global.set $first_row (i32.const 0)))
      (else (call $w8 (i32.const 44))))
    (call $w8 (i32.const 91))
    (local.set $n (select (global.get $spans_n) (global.get $width) (i32.lt_u (global.get $spans_n) (global.get $width))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.gt_u (local.get $i) (i32.const 0)) (then (call $w8 (i32.const 44))))
        (call $emit_field (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (block $pdone
      (loop $p
        (br_if $pdone (i32.ge_u (local.get $i) (global.get $width)))
        (call $w8 (i32.const 44))
        (call $w8 (i32.const 34)) (call $w8 (i32.const 34))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $p)))
    (call $w8 (i32.const 93))
    (global.set $rows_len (i32.add (global.get $rows_len) (i32.const 1))))

  ;; emit the current spans as the columns array
  (func $emit_columns
    (local $i i32)
    (call $w8 (i32.const 91))
    (local.set $i (i32.const 0))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (global.get $spans_n)))
        (if (i32.gt_u (local.get $i) (i32.const 0)) (then (call $w8 (i32.const 44))))
        (call $emit_field (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (call $w8 (i32.const 93)))

  ;; ---- errors (formatted eagerly into ERRBUF) ----
  (func $err_head (param $coff i32) (param $clen i32)
    (if (i32.gt_u (global.get $err_n) (i32.const 0)) (then (call $w8 (i32.const 44))))
    (global.set $err_n (i32.add (global.get $err_n) (i32.const 1)))
    (call $wlit (i32.const 0x22) (i32.const 9))
    (call $wbytes (i32.add (global.get $LIT_BASE) (local.get $coff)) (local.get $clen))
    (call $wlit (i32.const 0x2B) (i32.const 9))
    (call $wuint (global.get $rec_line))
    (call $wlit (i32.const 0x34) (i32.const 7))
    (call $wrow))
  (func $err_simple (param $coff i32) (param $clen i32)
    (call $use_err)
    (call $err_head (local.get $coff) (local.get $clen))
    (call $w8 (i32.const 125))
    (call $sync_err))
  (func $err_short (param $n i32)
    (call $use_err)
    (call $err_head (i32.const 0x77) (i32.const 9))
    (call $wlit (i32.const 0x3B) (i32.const 10))
    (call $wuint (local.get $n))
    (call $w8 (i32.const 125))
    (call $sync_err))
  (func $err_long (param $from i32)
    (local $i i32)
    (call $use_err)
    (call $err_head (i32.const 0x80) (i32.const 8))
    (call $wlit (i32.const 0x45) (i32.const 10))
    (local.set $i (local.get $from))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (global.get $spans_n)))
        (if (i32.gt_u (local.get $i) (local.get $from)) (then (call $w8 (i32.const 44))))
        (call $emit_field (local.get $i))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (call $w8 (i32.const 93))
    (call $w8 (i32.const 125))
    (call $sync_err))

  ;; ---- JSON input layer ----
  (func $jbyte (result i32)
    (if (result i32) (i32.lt_u (global.get $jp) (global.get $je))
      (then (i32.load8_u (global.get $jp)))
      (else (i32.const 0))))
  (func $jskip_ws
    (local $b i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (local.set $b (i32.load8_u (global.get $jp)))
        (if (i32.or (i32.or (i32.eq (local.get $b) (i32.const 32)) (i32.eq (local.get $b) (i32.const 9)))
              (i32.or (i32.eq (local.get $b) (i32.const 10)) (i32.eq (local.get $b) (i32.const 13))))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
        (br $done))))
  (func $jskip_string
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (if (i32.eq (i32.load8_u (global.get $jp)) (i32.const 92))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 2))) (br $l)))
        (if (i32.eq (i32.load8_u (global.get $jp)) (i32.const 34))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $done)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (br $l))))
  (func $jskip_value
    (local $b i32)
    (call $jskip_ws)
    (local.set $b (call $jbyte))
    (if (i32.eq (local.get $b) (i32.const 34)) (then (call $jskip_string) (return)))
    (if (i32.eq (local.get $b) (i32.const 123))
      (then
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (block $done
          (loop $l
            (call $jskip_ws)
            (br_if $done (i32.eq (call $jbyte) (i32.const 125)))
            (call $jskip_string)
            (call $jskip_ws)
            (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
            (call $jskip_value)
            (call $jskip_ws)
            (if (i32.eq (call $jbyte) (i32.const 44))
              (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
            (br $done)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (return)))
    (if (i32.eq (local.get $b) (i32.const 91))
      (then
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (block $done
          (loop $l
            (call $jskip_ws)
            (br_if $done (i32.eq (call $jbyte) (i32.const 93)))
            (call $jskip_value)
            (call $jskip_ws)
            (if (i32.eq (call $jbyte) (i32.const 44))
              (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
            (br $done)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (return)))
    ;; literal or number: run to the next delimiter
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (local.set $b (i32.load8_u (global.get $jp)))
        (if (i32.or (i32.or (i32.eq (local.get $b) (i32.const 44)) (i32.eq (local.get $b) (i32.const 125)))
              (i32.or (i32.eq (local.get $b) (i32.const 93)) (i32.le_u (local.get $b) (i32.const 32))))
          (then (br $done)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (br $l))))
  ;; parse a string key into KEYBUF (minimal unescaping); sets $klen
  (func $jkey
    (local $w i32) (local $b i32)
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.set $w (global.get $KEY_BASE))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (local.set $b (i32.load8_u (global.get $jp)))
        (if (i32.eq (local.get $b) (i32.const 34))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $done)))
        (if (i32.eq (local.get $b) (i32.const 92))
          (then
            (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
            (local.set $b (i32.load8_u (global.get $jp)))
            (if (i32.eq (local.get $b) (i32.const 117))
              (then (global.set $jp (i32.add (global.get $jp) (i32.const 5))) (local.set $b (i32.const 63)))
              (else
                (if (i32.eq (local.get $b) (i32.const 110)) (then (local.set $b (i32.const 10))))
                (if (i32.eq (local.get $b) (i32.const 114)) (then (local.set $b (i32.const 13))))
                (if (i32.eq (local.get $b) (i32.const 116)) (then (local.set $b (i32.const 9))))
                (if (i32.eq (local.get $b) (i32.const 98)) (then (local.set $b (i32.const 8))))
                (if (i32.eq (local.get $b) (i32.const 102)) (then (local.set $b (i32.const 12))))
                (global.set $jp (i32.add (global.get $jp) (i32.const 1)))))
            (i32.store8 (local.get $w) (local.get $b))
            (local.set $w (i32.add (local.get $w) (i32.const 1)))
            (br $l)))
        (i32.store8 (local.get $w) (local.get $b))
        (local.set $w (i32.add (local.get $w) (i32.const 1)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (br $l)))
    (global.set $klen (i32.sub (local.get $w) (global.get $KEY_BASE))))
  (func $jkey_is (param $off i32) (param $len i32) (result i32)
    (local $i i32)
    (if (i32.ne (global.get $klen) (local.get $len)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (if (i32.ne
              (i32.load8_u (i32.add (global.get $KEY_BASE) (local.get $i)))
              (i32.load8_u (i32.add (i32.add (global.get $LIT_BASE) (local.get $off)) (local.get $i))))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (i32.const 1))
  (func $hexval (param $b i32) (result i32)
    (if (i32.and (i32.ge_u (local.get $b) (i32.const 48)) (i32.le_u (local.get $b) (i32.const 57)))
      (then (return (i32.sub (local.get $b) (i32.const 48)))))
    (if (i32.and (i32.ge_u (local.get $b) (i32.const 97)) (i32.le_u (local.get $b) (i32.const 102)))
      (then (return (i32.sub (local.get $b) (i32.const 87)))))
    (if (i32.and (i32.ge_u (local.get $b) (i32.const 65)) (i32.le_u (local.get $b) (i32.const 70)))
      (then (return (i32.sub (local.get $b) (i32.const 55)))))
    (i32.const 0))
  (func $hex4 (result i32)
    (local $v i32)
    (local.set $v (call $hexval (i32.load8_u (global.get $jp))))
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.set $v (i32.add (i32.shl (local.get $v) (i32.const 4)) (call $hexval (i32.load8_u (global.get $jp)))))
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.set $v (i32.add (i32.shl (local.get $v) (i32.const 4)) (call $hexval (i32.load8_u (global.get $jp)))))
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.set $v (i32.add (i32.shl (local.get $v) (i32.const 4)) (call $hexval (i32.load8_u (global.get $jp)))))
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.get $v))
  (func $u8out (param $cp i32) (param $dst i32) (result i32)
    (if (i32.lt_u (local.get $cp) (i32.const 128))
      (then (i32.store8 (local.get $dst) (local.get $cp)) (return (i32.add (local.get $dst) (i32.const 1)))))
    (if (i32.lt_u (local.get $cp) (i32.const 2048))
      (then
        (i32.store8 (local.get $dst) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
        (return (i32.add (local.get $dst) (i32.const 2)))))
    (if (i32.lt_u (local.get $cp) (i32.const 65536))
      (then
        (i32.store8 (local.get $dst) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))
        (i32.store8 (i32.add (local.get $dst) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
        (return (i32.add (local.get $dst) (i32.const 3)))))
    (i32.store8 (local.get $dst) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
    (i32.add (local.get $dst) (i32.const 4)))
  (func $cesu8out (param $cp i32) (param $dst i32) (result i32)
    (i32.store8 (local.get $dst) (i32.const 237))
    (i32.store8 (i32.add (local.get $dst) (i32.const 1)) (i32.or (i32.const 160) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 15))))
    (i32.store8 (i32.add (local.get $dst) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))
    (i32.add (local.get $dst) (i32.const 3)))
  ;; unescape the "text" string at $jp into TEXT; sets $text_len
  (func $junescape_text
    (local $tw i32) (local $rem i32) (local $m i64) (local $n i32) (local $b i32) (local $e i32)
    (local $cp i32) (local $cp2 i32) (local $save i32)
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (local.set $tw (global.get $TEXT_BASE))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (local.set $rem (i32.sub (global.get $je) (global.get $jp)))
        (local.set $m (call $scanJ (global.get $jp) (local.get $rem)))
        (if (i64.eqz (local.get $m))
          (then
            (local.set $n (select (i32.const 64) (local.get $rem) (i32.gt_u (local.get $rem) (i32.const 64))))
            (memory.copy (local.get $tw) (global.get $jp) (local.get $n))
            (local.set $tw (i32.add (local.get $tw) (local.get $n)))
            (global.set $jp (i32.add (global.get $jp) (local.get $n)))
            (br $l)))
        (local.set $n (i32.wrap_i64 (i64.ctz (local.get $m))))
        (if (i32.gt_u (local.get $n) (i32.const 0))
          (then
            (memory.copy (local.get $tw) (global.get $jp) (local.get $n))
            (local.set $tw (i32.add (local.get $tw) (local.get $n)))))
        (global.set $jp (i32.add (global.get $jp) (local.get $n)))
        (local.set $b (i32.load8_u (global.get $jp)))
        (if (i32.eq (local.get $b) (i32.const 34))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $done)))
        ;; backslash escape
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (local.set $e (i32.load8_u (global.get $jp)))
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (if (i32.eq (local.get $e) (i32.const 34))
          (then (i32.store8 (local.get $tw) (i32.const 34)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 92))
          (then (i32.store8 (local.get $tw) (i32.const 92)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 47))
          (then (i32.store8 (local.get $tw) (i32.const 47)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 98))
          (then (i32.store8 (local.get $tw) (i32.const 8)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 102))
          (then (i32.store8 (local.get $tw) (i32.const 12)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 110))
          (then (i32.store8 (local.get $tw) (i32.const 10)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 114))
          (then (i32.store8 (local.get $tw) (i32.const 13)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 116))
          (then (i32.store8 (local.get $tw) (i32.const 9)) (local.set $tw (i32.add (local.get $tw) (i32.const 1))) (br $l)))
        (if (i32.eq (local.get $e) (i32.const 117))
          (then
            (local.set $cp (call $hex4))
            (if (i32.and (i32.ge_u (local.get $cp) (i32.const 55296)) (i32.le_u (local.get $cp) (i32.const 56319)))
              (then
                ;; high surrogate: look for a low-surrogate partner
                (if (i32.and
                      (i32.lt_u (i32.add (global.get $jp) (i32.const 1)) (global.get $je))
                      (i32.and
                        (i32.eq (i32.load8_u (global.get $jp)) (i32.const 92))
                        (i32.eq (i32.load8_u (i32.add (global.get $jp) (i32.const 1))) (i32.const 117))))
                  (then
                    (local.set $save (global.get $jp))
                    (global.set $jp (i32.add (global.get $jp) (i32.const 2)))
                    (local.set $cp2 (call $hex4))
                    (if (i32.and (i32.ge_u (local.get $cp2) (i32.const 56320)) (i32.le_u (local.get $cp2) (i32.const 57343)))
                      (then
                        (local.set $cp (i32.add (i32.const 65536)
                          (i32.add (i32.shl (i32.sub (local.get $cp) (i32.const 55296)) (i32.const 10))
                            (i32.sub (local.get $cp2) (i32.const 56320)))))
                        (local.set $tw (call $u8out (local.get $cp) (local.get $tw))))
                      (else
                        (global.set $jp (local.get $save))
                        (local.set $tw (call $cesu8out (local.get $cp) (local.get $tw))))))
                  (else (local.set $tw (call $cesu8out (local.get $cp) (local.get $tw))))))
              (else
                (if (i32.and (i32.ge_u (local.get $cp) (i32.const 56320)) (i32.le_u (local.get $cp) (i32.const 57343)))
                  (then (local.set $tw (call $cesu8out (local.get $cp) (local.get $tw))))
                  (else (local.set $tw (call $u8out (local.get $cp) (local.get $tw)))))))
            (br $l)))
        ;; unknown escape: keep the escaped byte as-is
        (i32.store8 (local.get $tw) (local.get $e))
        (local.set $tw (i32.add (local.get $tw) (i32.const 1)))
        (br $l)))
    (global.set $text_len (i32.sub (local.get $tw) (global.get $TEXT_BASE))))
  (func $jbool (result i32)
    (if (result i32) (i32.eq (call $jbyte) (i32.const 116))
      (then (global.set $jp (i32.add (global.get $jp) (i32.const 4))) (i32.const 1))
      (else
        (if (i32.eq (call $jbyte) (i32.const 102))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 5)))))
        (i32.const 0))))
  (func $parse_input_object
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (global.set $header (i32.const 0))
    (global.set $text_len (i32.const 0))
    (block $done
      (loop $l
        (call $jskip_ws)
        (if (i32.eq (call $jbyte) (i32.const 125))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (return)))
        (call $jkey)
        (call $jskip_ws)
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (call $jskip_ws)
        (if (call $jkey_is (i32.const 0x88) (i32.const 4))
          (then (call $junescape_text))
          (else
            (if (call $jkey_is (i32.const 0x8C) (i32.const 6))
              (then (global.set $header (call $jbool)))
              (else (call $jskip_value)))))
        (call $jskip_ws)
        (if (i32.eq (call $jbyte) (i32.const 44))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
        (br $done)))
    (call $jskip_ws)
    (if (i32.eq (call $jbyte) (i32.const 125))
      (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))))))
  (func $parse_case_object
    (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
    (block $done
      (loop $l
        (call $jskip_ws)
        (if (i32.eq (call $jbyte) (i32.const 125))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (return)))
        (call $jkey)
        (call $jskip_ws)
        (global.set $jp (i32.add (global.get $jp) (i32.const 1)))
        (call $jskip_ws)
        (if (call $jkey_is (i32.const 0x92) (i32.const 5))
          (then (call $parse_input_object))
          (else (call $jskip_value)))
        (call $jskip_ws)
        (if (i32.eq (call $jbyte) (i32.const 44))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
        (br $done)))
    (call $jskip_ws)
    (if (i32.eq (call $jbyte) (i32.const 125))
      (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))))))

  ;; ---- CSV parse (spans only; values stay in TEXT until emit) ----
  (func $push_span (param $s i32) (param $l i32) (param $k i32) (param $c i32)
    (local $base i32)
    (if (i32.ge_u (global.get $spans_n) (global.get $SPAN_CAP)) (then (return)))
    (local.set $base (i32.add (global.get $SPAN_BASE) (i32.mul (global.get $spans_n) (i32.const 16))))
    (i32.store (local.get $base) (local.get $s))
    (i32.store (i32.add (local.get $base) (i32.const 4)) (local.get $l))
    (i32.store (i32.add (local.get $base) (i32.const 8)) (local.get $k))
    (i32.store (i32.add (local.get $base) (i32.const 12)) (local.get $c))
    (global.set $spans_n (i32.add (global.get $spans_n) (i32.const 1))))

  ;; find the closing quote of the field opening at $tp; -1 when unterminated
  (func $prescan_close (result i32)
    (local $pos i32) (local $rem i32) (local $m i64) (local $q i32)
    (local.set $pos (i32.add (global.get $tp) (i32.const 1)))
    (block $done
      (loop $l
        (if (i32.ge_u (local.get $pos) (global.get $te)) (then (return (i32.const -1))))
        (local.set $rem (i32.sub (global.get $te) (local.get $pos)))
        (local.set $m (call $scanQ (local.get $pos) (local.get $rem)))
        (if (i64.eqz (local.get $m))
          (then
            (local.set $pos (i32.add (local.get $pos)
              (select (i32.const 64) (local.get $rem) (i32.gt_u (local.get $rem) (i32.const 64)))))
            (br $l)))
        (local.set $q (i32.add (local.get $pos) (i32.wrap_i64 (i64.ctz (local.get $m)))))
        (if (i32.and
              (i32.lt_u (i32.add (local.get $q) (i32.const 1)) (global.get $te))
              (i32.eq (i32.load8_u (i32.add (local.get $q) (i32.const 1))) (i32.const 34)))
          (then (local.set $pos (i32.add (local.get $q) (i32.const 2))) (br $l)))
        (return (local.get $q))))
    (i32.const -1))

  ;; parse an unquoted field from $tp; sets $uf_end/$uf_ended/$uf_added, moves $tp past the delimiter
  ;; $uf_ended: 0 comma, 1 line break, 2 end of text
  (func $parse_unquoted
    (local $start i32) (local $rem i32) (local $m i64) (local $p i32) (local $b i32) (local $stray i32)
    (local.set $start (global.get $tp))
    (local.set $stray (i32.const 0))
    (block $done
      (loop $l
        (if (i32.ge_u (global.get $tp) (global.get $te))
          (then
            (global.set $uf_end (global.get $te))
            (global.set $uf_ended (i32.const 2))
            (global.set $uf_added (i32.sub (i32.sub (global.get $te) (local.get $start)) (local.get $stray)))
            (br $done)))
        (local.set $rem (i32.sub (global.get $te) (global.get $tp)))
        (local.set $m (call $scanU (global.get $tp) (local.get $rem)))
        (if (i64.eqz (local.get $m))
          (then
            (global.set $tp (i32.add (global.get $tp)
              (select (i32.const 64) (local.get $rem) (i32.gt_u (local.get $rem) (i32.const 64)))))
            (br $l)))
        (local.set $p (i32.add (global.get $tp) (i32.wrap_i64 (i64.ctz (local.get $m)))))
        (local.set $b (i32.load8_u (local.get $p)))
        (if (i32.eq (local.get $b) (i32.const 44))
          (then
            (global.set $uf_end (local.get $p))
            (global.set $uf_ended (i32.const 0))
            (global.set $uf_added (i32.sub (i32.sub (local.get $p) (local.get $start)) (local.get $stray)))
            (global.set $tp (i32.add (local.get $p) (i32.const 1)))
            (br $done)))
        (if (i32.eq (local.get $b) (i32.const 10))
          (then
            (global.set $uf_end (local.get $p))
            (global.set $uf_ended (i32.const 1))
            (global.set $uf_added (i32.sub (i32.sub (local.get $p) (local.get $start)) (local.get $stray)))
            (global.set $tp (i32.add (local.get $p) (i32.const 1)))
            (global.set $line (i32.add (global.get $line) (i32.const 1)))
            (br $done)))
        ;; CR: CRLF ends the field, a lone CR is stray (error, dropped)
        (if (i32.and
              (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (global.get $te))
              (i32.eq (i32.load8_u (i32.add (local.get $p) (i32.const 1))) (i32.const 10)))
          (then
            (global.set $uf_end (local.get $p))
            (global.set $uf_ended (i32.const 1))
            (global.set $uf_added (i32.sub (i32.sub (local.get $p) (local.get $start)) (local.get $stray)))
            (global.set $tp (i32.add (local.get $p) (i32.const 2)))
            (global.set $line (i32.add (global.get $line) (i32.const 1)))
            (br $done)))
        (call $err_simple (i32.const 0x53) (i32.const 8))
        (local.set $stray (i32.add (local.get $stray) (i32.const 1)))
        (global.set $tp (i32.add (local.get $p) (i32.const 1)))
        (br $l))))

  ;; parse one record into the span table: 0 = no more, 1 = kept, 2 = skipped (stray-CR-only line)
  (func $parse_record (result i32)
    (local $b i32) (local $fs i32) (local $close i32) (local $ended i32)
    (local $cs i32) (local $clen i32) (local $kind i32) (local $jstart i32)
    ;; empty lines are no records
    (block $sk
      (loop $l
        (if (i32.ge_u (global.get $tp) (global.get $te)) (then (return (i32.const 0))))
        (local.set $b (i32.load8_u (global.get $tp)))
        (if (i32.eq (local.get $b) (i32.const 10))
          (then
            (global.set $tp (i32.add (global.get $tp) (i32.const 1)))
            (global.set $line (i32.add (global.get $line) (i32.const 1)))
            (br $l)))
        (if (i32.and
              (i32.eq (local.get $b) (i32.const 13))
              (i32.and
                (i32.lt_u (i32.add (global.get $tp) (i32.const 1)) (global.get $te))
                (i32.eq (i32.load8_u (i32.add (global.get $tp) (i32.const 1))) (i32.const 10))))
          (then
            (global.set $tp (i32.add (global.get $tp) (i32.const 2)))
            (global.set $line (i32.add (global.get $line) (i32.const 1)))
            (br $l)))
        (br $sk)))
    (global.set $rec_line (global.get $line))
    (if (i32.and (global.get $header) (i32.eqz (global.get $seen_first)))
      (then (global.set $rec_row (i32.const -1)))
      (else (global.set $rec_row (global.get $rows_len))))
    (global.set $spans_n (i32.const 0))
    (block $rec
      (loop $fields
        (local.set $fs (global.get $tp))
        (local.set $kind (i32.const 0))
        (local.set $cs (i32.const 0))
        (local.set $clen (i32.const 0))
        (if (i32.eq (i32.load8_u (global.get $tp)) (i32.const 34))
          (then
            (local.set $close (call $prescan_close))
            (if (i32.lt_s (local.get $close) (i32.const 0))
              (then
                ;; unterminated quote: literal quote, re-read as unquoted
                (call $err_simple (i32.const 0x65) (i32.const 18))
                (call $parse_unquoted)
                (call $push_span (local.get $fs) (i32.sub (global.get $uf_end) (local.get $fs)) (i32.const 0) (i32.const 0))
                (local.set $kind (i32.const 3))
                (local.set $ended (global.get $uf_ended)))
              (else
                (local.set $cs (i32.add (local.get $fs) (i32.const 1)))
                (local.set $clen (i32.sub (local.get $close) (local.get $cs)))
                (global.set $tp (i32.add (local.get $close) (i32.const 1)))
                (if (i32.ge_u (global.get $tp) (global.get $te))
                  (then
                    (local.set $kind (i32.const 1))
                    (local.set $ended (i32.const 2)))
                  (else
                    (local.set $b (i32.load8_u (global.get $tp)))
                    (if (i32.eq (local.get $b) (i32.const 44))
                      (then
                        (global.set $tp (i32.add (global.get $tp) (i32.const 1)))
                        (local.set $kind (i32.const 1))
                        (local.set $ended (i32.const 0)))
                      (else
                        (if (i32.eq (local.get $b) (i32.const 10))
                          (then
                            (global.set $tp (i32.add (global.get $tp) (i32.const 1)))
                            (global.set $line (i32.add (global.get $line) (i32.const 1)))
                            (local.set $kind (i32.const 1))
                            (local.set $ended (i32.const 1)))
                          (else
                            (if (i32.and
                                  (i32.eq (local.get $b) (i32.const 13))
                                  (i32.and
                                    (i32.lt_u (i32.add (global.get $tp) (i32.const 1)) (global.get $te))
                                    (i32.eq (i32.load8_u (i32.add (global.get $tp) (i32.const 1))) (i32.const 10))))
                              (then
                                (global.set $tp (i32.add (global.get $tp) (i32.const 2)))
                                (global.set $line (i32.add (global.get $line) (i32.const 1)))
                                (local.set $kind (i32.const 1))
                                (local.set $ended (i32.const 1)))
                              (else
                                ;; junk after the closing quote, appended as-is
                                (local.set $jstart (global.get $tp))
                                (call $parse_unquoted)
                                (if (i32.gt_u (global.get $uf_added) (i32.const 0))
                                  (then (call $err_simple (i32.const 0x5B) (i32.const 10))))
                                (local.set $kind (i32.const 2))
                                (local.set $ended (global.get $uf_ended))))))))))
                (if (i32.ne (local.get $kind) (i32.const 3))
                  (then
                    (if (i32.eq (local.get $kind) (i32.const 2))
                      (then
                        (call $push_span (local.get $cs)
                          (i32.sub (global.get $uf_end) (local.get $cs))
                          (i32.const 2) (local.get $clen)))
                      (else
                        (call $push_span (local.get $cs) (local.get $clen) (i32.const 1) (local.get $clen)))))))))
          (else
            (call $parse_unquoted)
            (call $push_span (local.get $fs) (i32.sub (global.get $uf_end) (local.get $fs)) (i32.const 0) (i32.const 0))
            (local.set $ended (global.get $uf_ended))))
        (if (i32.eq (local.get $ended) (i32.const 0)) (then (br $fields)))
        (br $rec)))
    ;; a line holding only stray CRs is no record (single unquoted span, nothing left after dropping CRs)
    (if (result i32)
      (i32.and (i32.eq (global.get $spans_n) (i32.const 1))
        (i32.and
          (i32.eqz (global.get $uf_added))
          (i32.eqz (i32.load (i32.add (global.get $SPAN_BASE) (i32.const 8))))))
      (then (i32.const 2))
      (else (i32.const 1))))

  ;; answer one case (TEXT already unescaped): {"columns":..,"rows":[..],"errors":[..]}
  (func $process_case
    (local $st i32)
    (global.set $line (i32.const 1))
    (global.set $rows_len (i32.const 0))
    (global.set $width (i32.const -1))
    (global.set $seen_first (i32.const 0))
    (global.set $spans_n (i32.const 0))
    (global.set $err_n (i32.const 0))
    (global.set $ep (global.get $ERR_BASE))
    (global.set $first_row (i32.const 1))
    (global.set $tp (global.get $TEXT_BASE))
    (global.set $te (i32.add (global.get $TEXT_BASE) (global.get $text_len)))
    (if (i32.and (i32.ge_u (global.get $text_len) (i32.const 3))
          (i32.and
            (i32.eq (i32.load8_u (global.get $tp)) (i32.const 239))
            (i32.and
              (i32.eq (i32.load8_u (i32.add (global.get $tp) (i32.const 1))) (i32.const 187))
              (i32.eq (i32.load8_u (i32.add (global.get $tp) (i32.const 2))) (i32.const 191)))))
      (then (global.set $tp (i32.add (global.get $tp) (i32.const 3)))))
    (block $found
      (loop $l
        (local.set $st (call $parse_record))
        (if (i32.eq (local.get $st) (i32.const 0))
          (then
            ;; no records at all
            (call $use_out)
            (call $wlit (i32.const 0x00) (i32.const 11))
            (if (global.get $header)
              (then (call $w8 (i32.const 91)) (call $w8 (i32.const 93)))
              (else (call $wlit (i32.const 0x4F) (i32.const 4))))
            (call $wlit (i32.const 0x0B) (i32.const 9))
            (call $wlit (i32.const 0x14) (i32.const 12))
            (call $wbytes (global.get $ERR_BASE) (i32.sub (global.get $ep) (global.get $ERR_BASE)))
            (call $wlit (i32.const 0x20) (i32.const 2))
            (call $sync_out)
            (return)))
        (if (i32.eq (local.get $st) (i32.const 2)) (then (br $l)))
        (br $found)))
    (global.set $seen_first (i32.const 1))
    (global.set $width (global.get $spans_n))
    (call $use_out)
    (call $wlit (i32.const 0x00) (i32.const 11))
    (call $sync_out)
    (if (global.get $header)
      (then (call $emit_columns))
      (else (call $wlit (i32.const 0x4F) (i32.const 4))))
    (call $wlit (i32.const 0x0B) (i32.const 9))
    (call $sync_out)
    (if (i32.eqz (global.get $header)) (then (call $emit_row)))
    (call $sync_out)
    (block $end
      (loop $l
        (local.set $st (call $parse_record))
        (if (i32.eq (local.get $st) (i32.const 0)) (then (br $end)))
        (if (i32.eq (local.get $st) (i32.const 2)) (then (br $l)))
        (if (i32.lt_u (global.get $spans_n) (global.get $width)) (then (call $err_short (global.get $spans_n))))
        (if (i32.gt_u (global.get $spans_n) (global.get $width)) (then (call $err_long (global.get $width))))
        (call $use_out)
        (call $emit_row)
        (call $sync_out)
        (br $l)))
    (call $use_out)
    (call $wlit (i32.const 0x14) (i32.const 12))
    (call $wbytes (global.get $ERR_BASE) (i32.sub (global.get $ep) (global.get $ERR_BASE)))
    (call $wlit (i32.const 0x20) (i32.const 2))
    (call $sync_out))

  ;; run(cases.json bytes) -> answers.json length; answers start at OUT_BASE
  (func (export "run") (param $len i32) (result i32)
    (local $first i32) (local $b i32)
    (global.set $jp (i32.const 0))
    (global.set $je (local.get $len))
    (global.set $op (global.get $OUT_BASE))
    (global.set $wp (global.get $OUT_BASE))
    (call $w8 (i32.const 91))
    (call $sync_out)
    (local.set $first (i32.const 1))
    (block $done
      (loop $l
        (call $jskip_ws)
        (br_if $done (i32.ge_u (global.get $jp) (global.get $je)))
        (local.set $b (call $jbyte))
        (if (i32.eq (local.get $b) (i32.const 93))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $done)))
        (if (i32.eq (local.get $b) (i32.const 91))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1))) (br $l)))
        (if (i32.eqz (local.get $first)) (then (call $w8 (i32.const 44)) (call $sync_out)))
        (local.set $first (i32.const 0))
        (call $parse_case_object)
        (call $process_case)
        (call $jskip_ws)
        (local.set $b (call $jbyte))
        (if (i32.eq (local.get $b) (i32.const 44))
          (then (global.set $jp (i32.add (global.get $jp) (i32.const 1)))))
        (br $l)))
    (call $w8 (i32.const 93))
    (global.set $op (global.get $wp))
    (i32.sub (global.get $op) (global.get $OUT_BASE)))
)
