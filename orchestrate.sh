
#!/usr/bin/env bash
# rheaOS build orchestrator - runs on a throwaway GitHub Actions runner.
# Stages: tc1 toolchain -> tc2 kernel -> tc3 userland -> tc4 rootfs/ISO
set -euo pipefail

ROOT="$(pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
SYSROOT="$ROOT/sysroot"
ARTIFACTS="$ROOT/artifacts"
JOBS="$(nproc)"

mkdir -p "$SRC" "$BUILD" "$SYSROOT" "$ARTIFACTS"

log() { echo "[$(date +%H:%M:%S)] $*"; }

fetch() {
  local url="$1" out="$SRC/$(basename "$1")"
  [ -f "$out" ] || wget -q --show-progress -O "$out" "$url"
}

# ---------- tc1: toolchain (binutils + zlib + glibc headers + gcc) ----------
stage_tc1() {
  log "tc1: toolchain"
  (
    fetch https://sourceware.org/pub/binutils/releases/binutils-2.43.1.tar.xz
    fetch https://zlib.net/zlib-1.3.1.tar.gz
    fetch https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz
    fetch https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz

    cd "$SRC"
    for t in binutils-2.43.1 zlib-1.3.1 glibc-2.40 gcc-14.2.0; do
      [ -d "$t" ] || tar xf "$t".tar.* 
    done

    # binutils
    log "  building binutils..."
    mkdir -p "$BUILD/binutils" && cd "$BUILD/binutils"
    "$SRC/binutils-2.43.1/configure" --prefix="$SYSROOT" --disable-nls --disable-werror
    make -j"$JOBS" || { log "ERROR: binutils build failed"; tail -50 "$BUILD/tc1.log"; exit 1; }
    make install

    # zlib (host copy, needed by gcc build)
    log "  building zlib..."
    cd "$SRC/zlib-1.3.1"
    ./configure --prefix="$SYSROOT"
    make -j"$JOBS" && make install

    # gcc pass 1 (minimal, C only, needed to build glibc)
    log "  building gcc pass 1..."
    cd "$SRC/gcc-14.2.0"
    mkdir -p "$BUILD/gcc-pass1" && cd "$BUILD/gcc-pass1"
    "$SRC/gcc-14.2.0/configure" --prefix="$SYSROOT" \
      --enable-languages=c --disable-multilib --without-headers \
      --disable-nls --disable-shared
    make -j"$JOBS" all-gcc all-target-libgcc || { log "ERROR: gcc pass 1 failed"; tail -100 config.log; exit 1; }
    make install-gcc install-target-libgcc

    # glibc
    log "  building glibc..."
    mkdir -p "$BUILD/glibc" && cd "$BUILD/glibc"
    PATH="$SYSROOT/bin:$PATH" "$SRC/glibc-2.40/configure" \
      --prefix="$SYSROOT" --disable-werror
    PATH="$SYSROOT/bin:$PATH" make -j"$JOBS" || { log "ERROR: glibc build failed"; tail -100 config.log; exit 1; }
    PATH="$SYSROOT/bin:$PATH" make install
  ) > "$BUILD/tc1.log" 2>&1 || { log "tc1 failed"; cat "$BUILD/tc1.log"; exit 8; }
}

# ---------- gcc-finish: full second pass gcc now that glibc exists ----------
stage_gcc_finish() {
  log "tc1: gcc finish (pass 2)"
  (
    log "  building gcc pass 2..."
    mkdir -p "$BUILD/gcc-pass2" && cd "$BUILD/gcc-pass2"
    PATH="$SYSROOT/bin:$PATH" "$SRC/gcc-14.2.0/configure" --prefix="$SYSROOT" \
      --enable-languages=c,c++ --disable-multilib --disable-nls
    PATH="$SYSROOT/bin:$PATH" make -j"$JOBS" || { log "ERROR: gcc pass 2 failed"; tail -100 config.log; exit 1; }
    PATH="$SYSROOT/bin:$PATH" make install
  ) >> "$BUILD/tc1.log" 2>&1 || { log "gcc finish failed"; tail -50 "$BUILD/tc1.log"; exit 1; }
}

# ---------- tc2: kernel ----------
stage_tc2() {
  log "tc2: kernel"
  (
    fetch https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.10.14.tar.xz
    cd "$SRC"
    [ -d linux-6.10.14 ] || tar xf linux-6.10.14.tar.xz
    cd linux-6.10.14
    make defconfig
    make -j"$JOBS"
    cp arch/x86/boot/bzImage "$ARTIFACTS/vmlinuz"
  ) > "$BUILD/tc2.log" 2>&1 || { log "tc2 failed"; tail -50 "$BUILD/tc2.log"; exit 1; }
}

# ---------- tc3: minimal userland ----------
stage_tc3() {
  log "tc3: userland"
  (
    fetch https://busybox.net/downloads/busybox-1.36.1.tar.bz2
    cd "$SRC"
    [ -d busybox-1.36.1 ] || tar xf busybox-1.36.1.tar.bz2
    cd busybox-1.36.1
    make defconfig
    make -j"$JOBS"
    make CONFIG_PREFIX="$SYSROOT" install
  ) > "$BUILD/tc3.log" 2>&1 || { log "tc3 failed"; tail -50 "$BUILD/tc3.log"; exit 1; }
}

# ---------- tc4: rootfs + disk.img + ISO ----------
stage_tc4() {
  log "tc4: rootfs/ISO"
  (
    ROOTFS="$BUILD/rootfs"
    mkdir -p "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,usr,lib}
    cp -a "$SYSROOT"/. "$ROOTFS"/usr/

    dd if=/dev/zero of="$ARTIFACTS/rheaos-disk.img" bs=1M count=512
    mkfs.ext4 -F -d "$ROOTFS" "$ARTIFACTS/rheaos-disk.img"

    ISODIR="$BUILD/isoroot"
    mkdir -p "$ISODIR/boot"
    cp "$ARTIFACTS/vmlinuz" "$ISODIR/boot/"
    cp "$ARTIFACTS/rheaos-disk.img" "$ISODIR/boot/"
    genisoimage -o "$ARTIFACTS/rheaos.iso" -b boot/vmlinuz -no-emul-boot "$ISODIR" || true
  ) > "$BUILD/tc4.log" 2>&1 || { log "tc4 failed"; tail -50 "$BUILD/tc4.log"; exit 1; }
}

main() {
  log "rheaOS build starting on $(nproc) cores"
  stage_tc1
  stage_gcc_finish
  stage_tc2
  stage_tc3
  stage_tc4
  log "done - artifacts in $ARTIFACTS"
  ls -la "$ARTIFACTS"
}

main "$@"
