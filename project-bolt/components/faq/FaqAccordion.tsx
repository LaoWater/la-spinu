'use client';

import { useState } from 'react';
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion';
import { Input } from '@/components/ui/input';
import { Search } from 'lucide-react';
import { FAQ_ITEMS } from '@/lib/constants';

export function FaqAccordion() {
  const [searchQuery, setSearchQuery] = useState('');
  
  const filteredFaqs = searchQuery
    ? FAQ_ITEMS.filter(
        (faq) =>
          faq.question.toLowerCase().includes(searchQuery.toLowerCase()) ||
          faq.answer.toLowerCase().includes(searchQuery.toLowerCase())
      )
    : FAQ_ITEMS;

  return (
    <div className="w-full max-w-3xl mx-auto">
      <div className="relative mb-8">
        <div className="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
          <Search className="h-5 w-5 text-muted-foreground" />
        </div>
        <Input
          type="text"
          placeholder="Caută în întrebările frecvente..."
          className="pl-10"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />
      </div>

      {filteredFaqs.length === 0 ? (
        <div className="text-center py-12">
          <p className="text-lg text-muted-foreground">
            Nu am găsit rezultate pentru "{searchQuery}".
          </p>
          <p className="mt-2">
            Încercați alte cuvinte cheie sau <button 
              onClick={() => setSearchQuery('')}
              className="text-primary underline"
            >
              ștergeți căutarea
            </button>.
          </p>
        </div>
      ) : (
        <Accordion type="single" collapsible className="w-full">
          {filteredFaqs.map((faq, index) => (
            <AccordionItem key={index} value={`item-${index}`}>
              <AccordionTrigger className="text-left font-medium">
                {faq.question}
              </AccordionTrigger>
              <AccordionContent className="text-muted-foreground">
                {faq.answer}
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      )}
    </div>
  );
}