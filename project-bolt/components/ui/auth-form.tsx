'use client';

import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useRouter } from 'next/navigation';
import { z } from 'zod';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Alert, AlertDescription } from '@/components/ui/alert';

const loginSchema = z.object({
  email: z.string().email({ message: 'Adresa de email invalidă' }),
  password: z.string().min(6, { message: 'Parola trebuie să aibă minim 6 caractere' }),
});

const signupSchema = loginSchema.extend({
  role: z.enum(['client', 'terapeut'], { required_error: 'Selectați un rol' }),
});

type LoginFormValues = z.infer<typeof loginSchema>;
type SignupFormValues = z.infer<typeof signupSchema>;

export function AuthForm() {
  const [formError, setFormError] = useState<string | null>(null);
  const [formSuccess, setFormSuccess] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('login');
  const { signIn, signUp } = useAuth();
  const router = useRouter();

  const loginForm = useForm<LoginFormValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: {
      email: '',
      password: '',
    },
  });

  const signupForm = useForm<SignupFormValues>({
    resolver: zodResolver(signupSchema),
    defaultValues: {
      email: '',
      password: '',
      role: 'client',
    },
  });

  const onLoginSubmit = async (data: LoginFormValues) => {
    setIsLoading(true);
    setFormError(null);
    
    try {
      const { error } = await signIn(data.email, data.password);
      
      if (error) {
        setFormError('Email sau parolă invalidă');
        return;
      }
      
      router.push('/');
    } catch (error) {
      setFormError('A apărut o eroare. Încercați din nou.');
    } finally {
      setIsLoading(false);
    }
  };

  const onSignupSubmit = async (data: SignupFormValues) => {
    setIsLoading(true);
    setFormError(null);
    
    try {
      const { error } = await signUp(data.email, data.password, data.role);
      
      if (error) {
        setFormError('Nu am putut crea contul. Verificați datele și încercați din nou.');
        return;
      }
      
      setFormSuccess('Cont creat cu succes! Acum vă puteți autentifica.');
      setActiveTab('login');
      signupForm.reset();
    } catch (error) {
      setFormError('A apărut o eroare. Încercați din nou.');
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Card className="w-full max-w-md mx-auto">
      <CardHeader>
        <CardTitle className="text-2xl font-bold text-center">Autentificare</CardTitle>
        <CardDescription className="text-center">
          Conectați-vă la contul dvs. sau creați unul nou
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full">
          <TabsList className="grid w-full grid-cols-2 mb-8">
            <TabsTrigger value="login">Autentificare</TabsTrigger>
            <TabsTrigger value="signup">Înregistrare</TabsTrigger>
          </TabsList>
          
          <TabsContent value="login">
            {formError && (
              <Alert variant="destructive" className="mb-4">
                <AlertDescription>{formError}</AlertDescription>
              </Alert>
            )}
            
            <Form {...loginForm}>
              <form onSubmit={loginForm.handleSubmit(onLoginSubmit)} className="space-y-4">
                <FormField
                  control={loginForm.control}
                  name="email"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Email</FormLabel>
                      <FormControl>
                        <Input placeholder="nume@exemplu.ro" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <FormField
                  control={loginForm.control}
                  name="password"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Parolă</FormLabel>
                      <FormControl>
                        <Input type="password" placeholder="••••••" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <Button type="submit" className="w-full" disabled={isLoading}>
                  {isLoading ? 'Se încarcă...' : 'Autentificare'}
                </Button>
              </form>
            </Form>
          </TabsContent>
          
          <TabsContent value="signup">
            {formError && (
              <Alert variant="destructive" className="mb-4">
                <AlertDescription>{formError}</AlertDescription>
              </Alert>
            )}
            
            {formSuccess && (
              <Alert variant="default" className="mb-4 bg-green-50 border-green-200 text-green-800">
                <AlertDescription>{formSuccess}</AlertDescription>
              </Alert>
            )}
            
            <Form {...signupForm}>
              <form onSubmit={signupForm.handleSubmit(onSignupSubmit)} className="space-y-4">
                <FormField
                  control={signupForm.control}
                  name="email"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Email</FormLabel>
                      <FormControl>
                        <Input placeholder="nume@exemplu.ro" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <FormField
                  control={signupForm.control}
                  name="password"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Parolă</FormLabel>
                      <FormControl>
                        <Input type="password" placeholder="••••••" {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <FormField
                  control={signupForm.control}
                  name="role"
                  render={({ field }) => (
                    <FormItem className="space-y-3">
                      <FormLabel>Tip de utilizator</FormLabel>
                      <FormControl>
                        <RadioGroup
                          onValueChange={field.onChange}
                          defaultValue={field.value}
                          className="flex flex-col space-y-1"
                        >
                          <FormItem className="flex items-center space-x-3 space-y-0">
                            <FormControl>
                              <RadioGroupItem value="client" />
                            </FormControl>
                            <FormLabel className="font-normal">Client</FormLabel>
                          </FormItem>
                          <FormItem className="flex items-center space-x-3 space-y-0">
                            <FormControl>
                              <RadioGroupItem value="terapeut" />
                            </FormControl>
                            <FormLabel className="font-normal">Terapeut</FormLabel>
                          </FormItem>
                        </RadioGroup>
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                
                <Button type="submit" className="w-full" disabled={isLoading}>
                  {isLoading ? 'Se încarcă...' : 'Înregistrare'}
                </Button>
              </form>
            </Form>
          </TabsContent>
        </Tabs>
      </CardContent>
      
      <CardFooter className="justify-center">
        <p className="text-sm text-muted-foreground">
          {activeTab === 'login' ? (
            <>
              Nu aveți cont?{' '}
              <button
                onClick={() => setActiveTab('signup')}
                className="text-primary hover:underline"
              >
                Înregistrați-vă
              </button>
            </>
          ) : (
            <>
              Aveți deja cont?{' '}
              <button
                onClick={() => setActiveTab('login')}
                className="text-primary hover:underline"
              >
                Autentificați-vă
              </button>
            </>
          )}
        </p>
      </CardFooter>
    </Card>
  );
}