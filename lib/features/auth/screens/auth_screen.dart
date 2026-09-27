import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../widgets/auth_validators.dart';
import '../../../core/config/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthMode { login, signup, forgot }

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, required this.mode});
  final AuthMode mode;
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _obscure = true;
  bool _resetBusy = false;
  String? _resetMessage;
  @override
  void dispose() {
    for (final c in [_email, _password, _confirm, _name, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final controller = ref.read(authProvider.notifier);
    if (widget.mode == AuthMode.forgot) {
      setState(() {
        _resetBusy = true;
        _resetMessage = null;
      });
      try {
        await ref
            .read(authRepositoryProvider)
            .forgotPassword(_email.text.trim());
        if (mounted) {
          setState(
            () => _resetMessage =
                ref.read(apiConfigProvider).useMocks &&
                    !SupabaseConfig.configured
                ? 'Demo only: no reset email was sent.'
                : 'If an account exists, reset instructions will be sent.',
          );
        }
      } catch (_) {
        if (mounted) {
          setState(
            () =>
                _resetMessage = 'Unable to request a reset. Please try again.',
          );
        }
      } finally {
        if (mounted) setState(() => _resetBusy = false);
      }
    } else if (widget.mode == AuthMode.signup) {
      await controller.signup(
        fullName: _name.text.trim(),
        email: _email.text.trim(),
        phone: _phone.text.trim(),
        password: _password.text,
      );
    } else {
      await controller.login(_email.text.trim(), _password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signup = widget.mode == AuthMode.signup;
    final forgot = widget.mode == AuthMode.forgot;
    final auth = ref.watch(authProvider);
    final busy = auth.isLoading || _resetBusy;
    final demo =
        !SupabaseConfig.configured && ref.watch(apiConfigProvider).useMocks;
    final authError = auth.error;
    final authErrorMessage = authError is AuthException
        ? authError.message
        : 'Unable to sign in. Check your details and connection, then try again.';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: busy ? null : () => context.go('/onboarding'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/branding/telomy-icon.png',
                    width: 64,
                    height: 64,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  forgot
                      ? 'Reset your password'
                      : signup
                      ? 'Begin your health story'
                      : 'Welcome back',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  forgot
                      ? 'We’ll help you get back to your account.'
                      : 'A little more understanding. Every day.',
                ),
                if (demo)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'DEMO MODE · Use sample details. Any valid form opens Alex’s demo profile. No account is created.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Form(
                  key: _form,
                  child: AutofillGroup(
                    child: Column(
                      children: [
                        if (signup) ...[
                          TextFormField(
                            controller: _name,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              labelText: 'Full name',
                            ),
                            validator: AuthValidators.name,
                            textCapitalization: TextCapitalization.words,
                            autofillHints: const [AutofillHints.name],
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _phone,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              labelText: 'Phone',
                            ),
                            validator: AuthValidators.phone,
                            keyboardType: TextInputType.phone,
                            autofillHints: const [
                              AutofillHints.telephoneNumber,
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextFormField(
                          controller: _email,
                          enabled: !busy,
                          decoration: const InputDecoration(labelText: 'Email'),
                          validator: AuthValidators.email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.email],
                        ),
                        if (!forgot) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _password,
                            enabled: !busy,
                            obscureText: _obscure,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: [
                              signup
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
                                tooltip: _obscure
                                    ? 'Show password'
                                    : 'Hide password',
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                            validator: AuthValidators.password,
                          ),
                        ],
                        if (signup) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _confirm,
                            enabled: !busy,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                            ),
                            validator: (value) => value == _password.text
                                ? null
                                : 'Passwords do not match',
                          ),
                        ],
                        if (auth.hasError && !forgot)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(authErrorMessage),
                          ),
                        if (_resetMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(_resetMessage!),
                          ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: busy ? null : _submit,
                            child: busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    forgot
                                        ? 'Send reset instructions'
                                        : signup
                                        ? 'Create account'
                                        : 'Sign in',
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!signup && !forgot)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => context.go('/forgot-password'),
                    child: const Text('Forgot password?'),
                  ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () =>
                            context.go(signup || forgot ? '/login' : '/signup'),
                  child: Text(
                    signup || forgot
                        ? 'Back to sign in'
                        : 'New here? Create an account',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
