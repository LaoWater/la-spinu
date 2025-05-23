import { AuthForm } from '@/components/ui/auth-form';

export const metadata = {
  title: 'Autentificare | TerapieAcasa.ro',
  description: 'Conectează-te la contul tău sau creează un cont nou',
};

export default function AuthPage() {
  return (
    <div className="container max-w-7xl mx-auto my-12 px-4 md:my-20">
      <div className="text-center mb-10">
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          Contul tău TerapieAcasa
        </h1>
        <p className="mt-4 text-lg text-muted-foreground">
          Conectează-te la contul tău sau creează un cont nou pentru a accesa serviciile noastre
        </p>
      </div>
      
      <AuthForm />
    </div>
  );
}