import 'package:flutter/material.dart';
import '../services/odoo_service.dart';
import 'orders_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _odooService = OdooService();
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _confirmPinCtrl = TextEditingController();

  bool _isCheckingPhone = false;
  bool _phoneChecked = false;
  bool _needsPinCreation = false;
  String? _riderName;
  String? _errorMessage;

  static const Color sokoNavy = Color(0xFF0C2340);
  static const Color sokoGreen = Color(0xFF3CA227);

  Future<void> _checkPhone() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _errorMessage = 'Please enter your phone number.');
      return;
    }

    setState(() {
      _isCheckingPhone = true;
      _errorMessage = null;
    });

    final res = await _odooService.checkStatus(phone);

    setState(() => _isCheckingPhone = false);

    if (res['status'] == 'ready') {
      setState(() {
        _phoneChecked = true;
        _needsPinCreation = res['needs_pin_creation'] == true;
        _riderName = res['rider_name'];
      });
    } else {
      setState(() {
        _errorMessage = res['message'] ?? 'Could not verify account.';
      });
    }
  }

  Future<void> _submitPin() async {
    final pin = _pinCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();

    if (pin.length < 4 || pin.length > 6) {
      setState(() => _errorMessage = 'PIN must be 4 to 6 digits.');
      return;
    }

    if (_needsPinCreation) {
      final confirm = _confirmPinCtrl.text.trim();
      if (pin != confirm) {
        setState(() => _errorMessage = 'PINs do not match.');
        return;
      }

      setState(() => _isCheckingPhone = true);
      final createRes = await _odooService.createPin(phone, pin);
      if (createRes['success'] != true) {
        setState(() {
          _isCheckingPhone = false;
          _errorMessage = createRes['message'] ?? 'Error saving PIN.';
        });
        return;
      }
    }

    setState(() => _isCheckingPhone = true);
    final success = await _odooService.login(phone, pin);
    setState(() => _isCheckingPhone = false);

    if (success && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OrdersScreen(odooService: _odooService),
        ),
      );
    } else if (mounted) {
      setState(() => _errorMessage = 'Invalid PIN. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Soko Rider Badge
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: sokoNavy,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: sokoNavy.withOpacity(0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('🛵', style: TextStyle(fontSize: 38)),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Soko Express Mtaani',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: sokoNavy),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Rider Delivery & Telematics Portal',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 32),

                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_errorMessage!, style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
                  ),

                if (!_phoneChecked) ...[
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Registered Phone Number',
                      hintText: 'e.g. 0712345678',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                      prefixIcon: const Icon(Icons.phone_android, color: sokoNavy),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _isCheckingPhone ? null : _checkPhone,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: sokoNavy,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: _isCheckingPhone
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEBF7E7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.verified, color: sokoGreen, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Welcome, ${_riderName ?? "Rider"}!', style: const TextStyle(fontWeight: FontWeight.bold, color: sokoNavy)),
                              Text(_needsPinCreation ? 'Create your secret 4-digit PIN' : 'Enter your 4-digit PIN', style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      labelText: _needsPinCreation ? 'Create 4-Digit PIN' : 'Enter PIN',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                      prefixIcon: const Icon(Icons.lock_outline, color: sokoGreen),
                    ),
                  ),
                  if (_needsPinCreation) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirmPinCtrl,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      decoration: InputDecoration(
                        labelText: 'Confirm PIN',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                        prefixIcon: const Icon(Icons.lock_reset, color: sokoGreen),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _isCheckingPhone ? null : _submitPin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: sokoGreen,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: _isCheckingPhone
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(_needsPinCreation ? 'Activate & Login' : 'Login to Deliveries', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() => _phoneChecked = false),
                    child: const Text('Change Phone Number', style: TextStyle(color: Color(0xFF64748B))),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
