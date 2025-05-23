'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { z } from 'zod';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card';
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group';
import { Textarea } from '@/components/ui/textarea';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { TERAPIE_TIPURI, TERAPEUT_GEN, TERAPEUT_VARSTA } from '@/lib/constants';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { CheckCircle } from 'lucide-react';

const preferenceSchema = z.object({
  tipTerapie: z.string({ required_error: 'Vă rugăm să selectați un tip de terapie' }),
  genTerapeut: z.string({ required_error: 'Vă rugăm să selectați genul preferat' }),
  varstaTerapeut: z.string({ required_error: 'Vă rugăm să selectați grupa de vârstă preferată' }),
  altePreferinte: z.string().optional(),
});

type PreferenceFormValues = z.infer<typeof preferenceSchema>;

export function ClientPreferenceForm() {
  const [isLoading, setIsLoading] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [formSuccess, setFormSuccess] = useState(false);
  const router = useRouter();

  const form = useForm<PreferenceFormValues>({
    resolver: zodResolver(preferenceSchema),
    defaultValues: {
      tipTerapie: '',
      genTerapeut: '',
      varstaTerapeut: '',
      altePreferinte: '',
    },
  });

  const onSubmit = async (data: PreferenceFormValues) => {
    setIsLoading(true);
    setFormError(null);
    
    try {
      // Simulate API call
      console.log('Form data submitted:', data);
      
      // Simulate successful submission
      await new Promise(resolve => setTimeout(resolve, 1500));
      
      setFormSuccess(true);
    } catch (error) {
      setFormError('A apărut o eroare. Vă rugăm să încercați din nou.');
    } finally {
      setIsLoading(false);
    }
  };

  if (formSuccess) {
    return (
      <Card className="w-full max-w-3xl mx-auto">
        <CardContent className="pt-6 text-center">
          <div className="flex justify-center mb-6">
            <CheckCircle className="h-20 w-20 text-green-500" />
          </div>
          
          <CardTitle className="text-2xl font-bold mb-4">
            Mulțumim pentru completarea formularului!
          </CardTitle>
          
          <CardDescription className="text-lg mb-8">
            Preferințele tale au fost trimise. Te vom contacta în curând cu informații despre terapeuții potriviți pentru nevoile tale.
          </CardDescription>
          
          <div className="flex flex-col sm:flex-row gap-4 justify-center">
            <Button onClick={() => router.push('/')} variant="outline">
              Înapoi la pagina principală
            </Button>
            
            <Button onClick={() => {
              setFormSuccess(false);
              form.reset();
            }}>
              Completează un nou formular
            </Button>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="w-full max-w-3xl mx-auto">
      <CardHeader>
        <CardTitle className="text-2xl font-bold">
          Preferințele tale pentru terapie
        </CardTitle>
        <CardDescription>
          Completează câteva detalii pentru a găsi terapeutul potrivit pentru tine.
        </CardDescription>
      </CardHeader>
      
      <CardContent>
        {formError && (
          <Alert variant="destructive" className="mb-6">
            <AlertDescription>{formError}</AlertDescription>
          </Alert>
        )}
        
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">
            <FormField
              control={form.control}
              name="tipTerapie"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Tip de terapie</FormLabel>
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Selectați tipul de terapie" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {TERAPIE_TIPURI.map((tip) => (
                        <SelectItem key={tip.value} value={tip.value}>
                          {tip.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />
            
            <FormField
              control={form.control}
              name="genTerapeut"
              render={({ field }) => (
                <FormItem className="space-y-3">
                  <FormLabel>Genul terapeutului preferat</FormLabel>
                  <FormControl>
                    <RadioGroup
                      onValueChange={field.onChange}
                      defaultValue={field.value}
                      className="flex flex-col space-y-1"
                    >
                      {TERAPEUT_GEN.map((gen) => (
                        <FormItem key={gen.value} className="flex items-center space-x-3 space-y-0">
                          <FormControl>
                            <RadioGroupItem value={gen.value} />
                          </FormControl>
                          <FormLabel className="font-normal">
                            {gen.label}
                          </FormLabel>
                        </FormItem>
                      ))}
                    </RadioGroup>
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            
            <FormField
              control={form.control}
              name="varstaTerapeut"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Grupa de vârstă a terapeutului</FormLabel>
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Selectați grupa de vârstă preferată" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {TERAPEUT_VARSTA.map((varsta) => (
                        <SelectItem key={varsta.value} value={varsta.value}>
                          {varsta.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />
            
            <FormField
              control={form.control}
              name="altePreferinte"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Alte preferințe (opțional)</FormLabel>
                  <FormControl>
                    <Textarea
                      placeholder="Detalii suplimentare despre preferințele tale legate de terapie sau terapeut..."
                      className="resize-none"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            
            <Button type="submit" className="w-full" size="lg" disabled={isLoading}>
              {isLoading ? 'Se procesează...' : 'Caută terapeut'}
            </Button>
          </form>
        </Form>
      </CardContent>
      
      <CardFooter className="flex justify-center border-t pt-6">
        <p className="text-sm text-muted-foreground">
          Datele tale sunt protejate și folosite doar pentru a te conecta cu terapeuții potriviți.
        </p>
      </CardFooter>
    </Card>
  );
}