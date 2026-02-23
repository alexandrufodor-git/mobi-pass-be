-- ============================================
-- Add images JSONB array column to bikes table
-- Drop the old single image_url column
-- Populate 5 gallery images per bike from Maros Bike CDN
-- ============================================

ALTER TABLE public.bikes
  ADD COLUMN IF NOT EXISTS images JSONB;

-- ============================================
-- Populate images for each bike by ID
-- ============================================

-- Cube COMPACT HYBRID 545
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/7/bicicleta-electrica-cube-compact-hybrid-545-royalgreen-black-2026-20~8374467.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-compact-hybrid-545-royalgreen-black-2026-20~8374470.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-compact-hybrid-545-royalgreen-black-2026-20~8374473.jpg","https://c.cdnmp.net/183479982/p/l/6/bicicleta-electrica-cube-compact-hybrid-545-royalgreen-black-2026-20~8374476.jpg","https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-compact-hybrid-545-royalgreen-black-2026-20~8374479.jpg"]'
WHERE id = '110684dd-0b81-4795-aaca-8e95c301003c';

-- Cube TRIKE HYBRID CARGO 750
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/9/cube-trike-hybrid-cargo-750-grey-n-reflex~394219.jpg","https://c.cdnmp.net/183479982/p/l/0/cube-trike-hybrid-cargo-750-grey-n-reflex~394220.jpg","https://c.cdnmp.net/183479982/p/l/1/cube-trike-hybrid-cargo-750-grey-n-reflex~394221.jpg","https://c.cdnmp.net/183479982/p/l/2/cube-trike-hybrid-cargo-750-grey-n-reflex~394222.jpg","https://c.cdnmp.net/183479982/p/l/3/cube-trike-hybrid-cargo-750-grey-n-reflex~394223.jpg"]'
WHERE id = '12b08b71-6142-4c2b-9c0c-05f21fc9660e';

-- Marin RIFT ZONE E2 SM
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/5/bicicleta-electrica-marin-rift-zone-e2-sm-sand-black-29~8381445.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-marin-rift-zone-e2-sm-sand-black-29~8381442.jpg","https://c.cdnmp.net/183479982/p/l/8/bicicleta-electrica-marin-rift-zone-e2-sm-sand-black-29~8381448.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-marin-rift-zone-e2-sm-sand-black-29~8381451.jpg","https://c.cdnmp.net/183479982/p/l/4/bicicleta-electrica-marin-rift-zone-e2-sm-sand-black-29~8381454.jpg"]'
WHERE id = '15864ba2-6c09-45e2-bc68-6a0003f43132';

-- Cube STEREO HYBRID ONE77 HPC SLX 800 (XL)
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396069.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396070.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396071.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396072.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396073.jpg"]'
WHERE id = '1ca57dc3-67de-44ee-86e2-2ae857fb6a1b';

-- Cube REACTION HYBRID PERFORMANCE 600 (M)
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/4/bicicleta-electrica-cube-reaction-hybrid-performance-625-night-black~403264.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-reaction-hybrid-performance-625-night-black~396580.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-cube-reaction-hybrid-performance-625-night-black~396581.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-cube-reaction-hybrid-performance-625-night-black~396582.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-reaction-hybrid-performance-625-night-black~396583.jpg"]'
WHERE id = '210c256b-f41f-4997-b9e4-a798fd2a89b8';

-- Focus SAM 2 6.8 (grey + urban green variants)
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-focus-sam-2-6-8-29-grey~394540.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-focus-sam-2-6-8-29-grey~394541.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-focus-sam-2-6-8-29-grey~394542.jpg","https://c.cdnmp.net/183479982/p/l/8/bicicleta-electrica-focus-sam-2-6-8-29-600wh-urban-green-magic-black~420818.jpg","https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-focus-sam-2-6-8-29-600wh-urban-green-magic-black~420819.jpg"]'
WHERE id = '58500e63-0957-491d-958c-5e8e86f519b0';

-- Amflow PL CARBON PRO
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/5/bicicleta-electrica-amflow-pl-carbon-pro-cosmic-black-29~8376615.jpg","https://c.cdnmp.net/183479982/p/l/8/bicicleta-electrica-amflow-pl-carbon-pro-cosmic-black-29~8376618.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-amflow-pl-carbon-pro-cosmic-black-29~8376621.jpg","https://c.cdnmp.net/183479982/p/l/4/bicicleta-electrica-amflow-pl-carbon-pro-cosmic-black-29~8376624.jpg","https://c.cdnmp.net/183479982/p/l/7/bicicleta-electrica-amflow-pl-carbon-pro-cosmic-black-29~8376627.jpg"]'
WHERE id = '69f2ed62-63d0-4fef-a0eb-b067ca33a852';

-- Cube NURIDE HYBRID PERFORMANCE 600
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-nuride-hybrid-pro-600-easy-entry-chilli-black~8370720.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-nuride-hybrid-pro-600-easy-entry-chilli-black~8370723.jpg","https://c.cdnmp.net/183479982/p/l/6/bicicleta-electrica-cube-nuride-hybrid-pro-600-easy-entry-chilli-black~8370726.jpg","https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-nuride-hybrid-pro-600-easy-entry-chilli-black~8370729.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-cube-nuride-hybrid-pro-600-easy-entry-chilli-black~8370732.jpg"]'
WHERE id = '9c1c6822-33eb-4bae-aed6-32af0ee70afb';

-- Cube KATHMANDU HYBRID PRO 800
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/7/bicicleta-electrica-cube-kathmandu-hybrid-comfort-pro-800-easy-entry~8390537.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-kathmandu-hybrid-comfort-pro-800-easy-entry~8390540.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-kathmandu-hybrid-comfort-pro-800-easy-entry~8390543.jpg","https://c.cdnmp.net/183479982/p/l/6/bicicleta-electrica-cube-kathmandu-hybrid-comfort-pro-800-easy-entry~8390546.jpg","https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-kathmandu-hybrid-comfort-pro-800-easy-entry~8390549.jpg"]'
WHERE id = 'b5a14e46-1185-4f0d-ab3a-11b373722491';

-- Cube ACID 240 HYBRID ROOKIE SLX 400X
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/6/bicicleta-electrica-cube-acid-240-hybrid-rookie-slx-500-dustyolive~394926.jpg","https://c.cdnmp.net/183479982/p/l/7/bicicleta-electrica-cube-acid-240-hybrid-rookie-slx-500-dustyolive~394927.jpg","https://c.cdnmp.net/183479982/p/l/8/bicicleta-electrica-cube-acid-240-hybrid-rookie-slx-500-dustyolive~394928.jpg","https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-acid-240-hybrid-rookie-slx-500-dustyolive~394929.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-acid-240-hybrid-rookie-slx-500-dustyolive~394930.jpg"]'
WHERE id = 'd37e1e27-279a-4340-8323-f072722cc820';

-- Cube STEREO HYBRID ONE77 HPC SLX 800 (M) — same model, same images
UPDATE public.bikes SET images = '["https://c.cdnmp.net/183479982/p/l/9/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396069.jpg","https://c.cdnmp.net/183479982/p/l/0/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396070.jpg","https://c.cdnmp.net/183479982/p/l/1/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396071.jpg","https://c.cdnmp.net/183479982/p/l/2/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396072.jpg","https://c.cdnmp.net/183479982/p/l/3/bicicleta-electrica-cube-stereo-hybrid-one77-hpc-slx-blackline-2025-29~396073.jpg"]'
WHERE id = 'e1324a39-901f-4825-8d6c-ebee074b15a5';
