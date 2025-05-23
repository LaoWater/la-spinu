import { HeroSection } from '@/components/home/HeroSection';
import { FeaturesSection } from '@/components/home/FeaturesSection';
import { StepsSection } from '@/components/home/StepsSection';
import { TestimonialsSection } from '@/components/home/TestimonialsSection';
import { CtaSection } from '@/components/home/CtaSection';

export default function Home() {
  return (
    <>
      <HeroSection />
      <FeaturesSection />
      <StepsSection />
      <TestimonialsSection />
      <CtaSection />
    </>
  );
}