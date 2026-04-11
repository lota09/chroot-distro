# Adreno GPU Acceleration Architecture for Chroot-Distro

This document provides a technical deep-dive into the graphics and compute stack used to bridge Android hardware with the Chroot-Linux environment.

## 1. The Core Stack: A Hierarchical View

Understanding how "OpenGL" commands reach the "Snapdragon GPU" requires looking at a multi-layered translation stack.

| **방식명** | **게스트 드라이버** | **통신 수단** | **호스트 백엔드** | **최종 연산 장치** |
| --- | --- | --- | --- | --- |
| **LLVMPIPE** | `llvmpipe` | 없음 (로컬) | 없음 | **CPU** (소프트웨어 연산) |
| **VIRGL (기본)** | `virpipe` | 유닉스 소켓 | `virgl_test_server` (기본) | **CPU** (호스트 CPU 연산) |
| **VIRGL + ZINK** | `virpipe` | 유닉스 소켓 | `virgl_test_server` (**Zink** 상단) | **GPU** (Adreno 하드웨어) |
| **TURNIP + ZINK** | `zink` | 하위 장치 직접 접근 | 없음 (직접 구동) | **GPU** (Adreno 하드웨어) |

| Layer | Component | Role | Description |
| :--- | :--- | :--- | :--- |
| **API** | **OpenGL / Vulkan** | Interface | The standard commands sent by apps (e.g., "Draw Triangle"). |
| **Translator**| **ZINK** | Translation | A Mesa driver that translates OpenGL commands into Vulkan. |
| **Driver** | **TURNIP** | Execution | The open-source Vulkan driver for Adreno GPUs (Mesa). |
| **Hardware** | **Adreno GPU** | Processing | The physical silicon that performs the math. |

> [!IMPORTANT]
> Adreno hardware (Snapdragon) primarily speaks **Vulkan**. To run standard Linux desktop environments (which are OpenGL-heavy), **ZINK** acts as a vital bridge.

---

## 2. Communication Models: Bridged vs. Direct

Depending on the display environment (VNC vs. X11), we use different paths to reach the hardware.

### A. Bridged Model (VIRGL + ZINK)
Used primarily for **VNC (:1)** or headless sessions.
- **Workflow:** `Guest App (OpenGL)` → `Virpipe (Socket)` → `Host Virgl Server` → `Zink` → `Turnip` → `GPU`.
- **Why?** VNC is a "dumb" pixel buffer. It cannot understand 3D commands. The **Virgl Server** on the host acts as a high-powered "drawing agent" that renders the 3D commands into pixels and dumps them into the VNC buffer.

### B. Direct Model (TURNIP + ZINK)
Used primarily for **Termux-X11 (:0)**.
- **Workflow:** `Guest App (OpenGL)` → `Zink` → `Turnip` → `GPU` → `Direct Surface (X11)`.
- **Why?** Termux-X11 provides a native Android "Surface". The GPU can draw directly onto this surface without a middleman server, resulting in near-native performance.

---

## 3. The Comparison Matrix

| Option | Path | Speed | Best For |
| :--- | :--- | :--- | :--- |
| **LLVMPIPE** | CPU-Only | 🐢 Slow | Emergency / No-GPU targets |
| **VIRGL (Basic)** | Socket -> Host CPU | 🐕 Moderate | VNC on low-end hardware |
| **VIRGL + ZINK** | Socket -> Host GPU | 🚄 Fast | Accelerated VNC sessions |
| **TURNIP + ZINK** | Direct to GPU | 🚀 Native | Native-like gaming / Heavy GUI |

---

## 4. Display Synchronization Strategies

### Independent Displays (:0 and :1)
Running X11 on `:0` and VNC on `:1` creates two separate desktops. The VNC desktop (:1) **must** use the Bridged (VIRGL) model to get acceleration, as it has no connection to the X11 hardware surface.

### Combined Mirroring (X11 + x11vnc)
Running `x11vnc` on top of `:0` allows VNC clients to see the hardware-accelerated X11 screen. This bypasses the need for the VIRGL server while providing the highest possible 3D performance to the VNC viewer.

---
*Created on 2026-04-11 - Chroot-Distro Engineering Team*
