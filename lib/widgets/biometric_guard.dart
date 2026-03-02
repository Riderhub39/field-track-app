import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

// 🟢 引入控制器
import 'biometric_guard_controller.dart';

class BiometricGuard extends ConsumerStatefulWidget {
  final Widget child;

  const BiometricGuard({super.key, required this.child});

  @override
  ConsumerState<BiometricGuard> createState() => _BiometricGuardState();
}

class _BiometricGuardState extends ConsumerState<BiometricGuard> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Provider 的初始化已经在其构造函数中自动执行了 checkInitialStatus()
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.paused) {
      ref.read(biometricGuardProvider.notifier).handleAppPaused();
    } else if (appState == AppLifecycleState.resumed) {
      ref.read(biometricGuardProvider.notifier).handleAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(biometricGuardProvider);

    return Stack(
      children: [
        // 1. 底层实际的 App 界面
        widget.child,

        // 2. 锁定屏幕覆盖层
        if (state.isLocked)
          Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30.0, vertical: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    
                    // --- 1. Logo Area ---
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        "FIELDTRACK PRO", 
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF15438c), letterSpacing: 1.5),
                      ),
                    ),

                    const SizedBox(height: 60),

                    // --- 2. Welcome Text ---
                    Text(
                      "lock.welcome_back".tr(),
                      style: const TextStyle(fontSize: 18, color: Colors.black54),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state.cachedName.toUpperCase(), 
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 26, 
                        fontWeight: FontWeight.bold, 
                        color: Color(0xFF15438c)
                      ),
                    ),

                    const Spacer(), 

                    // --- 3. Fingerprint Icon ---
                    Text(
                      "lock.verify_identity".tr(),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 20),
                    
                    GestureDetector(
                      onTap: () => ref.read(biometricGuardProvider.notifier).authenticate(),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.blue.shade100, width: 2),
                        ),
                        child: const Icon(
                          Icons.fingerprint, 
                          size: 70, 
                          color: Colors.blue
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 15),
                    Text(
                      "lock.touch_sensor".tr(),
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),

                    const Spacer(),

                    // --- 4. Relogin Button ---
                    TextButton(
                      onPressed: () => ref.read(biometricGuardProvider.notifier).handleRelogin(),
                      child: Text(
                        "lock.relogin".tr(),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF15438c)),
                      ),
                    ),

                    const SizedBox(height: 30),

                    // --- 5. Footer ---
                    Text(
                      "Version 1.0.0",
                      style: TextStyle(color: Colors.blue.shade800, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 20),
                    
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        Text("lock.footer_text".tr(), style: const TextStyle(fontSize: 11, color: Colors.black54), textAlign: TextAlign.center),
                        GestureDetector(
                          onTap: () {}, 
                          child: Text("lock.privacy".tr(), style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold)),
                        ),
                        const Text("&", style: TextStyle(fontSize: 11, color: Colors.black54)),
                        GestureDetector(
                          onTap: () {},
                          child: Text("lock.terms".tr(), style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold)),
                        ),
                        const Text(".", style: TextStyle(fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}